import Foundation

public struct SpreadsheetError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// Converts table files into Loupe's Workbook model.
public enum SpreadsheetReader {
    public static let maxRows = 1_000_000
    /// How many empty rows a merge or a far custom height may add past the last real row.
    public static let maxLayoutPadding = 100_000
    /// UTF-16/32 must be decoded as a whole String. Larger files are refused.
    public static let wideTextLimit = 32 * 1024 * 1024

    // MARK: CSV / TSV

    public static func readDelimited(url: URL, delimiter: UInt8?) throws -> Workbook {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let enc = TextEncodingDetector.detect(data.prefix(256 * 1024))
        if enc.unitWidth > 1 && data.count > wideTextLimit {
            throw SpreadsheetError(message: "UTF-16/32 表格超过 32MB，已停止载入以免占满内存")
        }
        var bytes: Data
        var stringEncoding: String.Encoding = .utf8
        if enc.unitWidth > 1 {
            bytes = Data(TextEncodingDetector.decode(data, as: enc).utf8)
        } else {
            bytes = enc.bomLength > 0 ? data.dropFirst(enc.bomLength) : data
            stringEncoding = enc.encoding
        }
        let head = TextSniffer.leadingText(data, max: 16 * 1024)
        let delim = delimiter ?? CSVSniffer.sniffDelimiter(head) ?? 44
        var parser = CSVParser(delimiter: delim, encoding: stringEncoding)
        var rows = parser.feed(bytes)
        if let last = parser.finish() { rows.append(last) }
        bytes = Data()
        if rows.count > maxRows { rows = Array(rows.prefix(maxRows)) }
        let cells = rows.map { $0.map(CellValue.infer) }
        var wb = Workbook(sheets: [Sheet(name: url.deletingPathExtension().lastPathComponent, rows: cells)],
                          source: delim == 9 ? "TSV · \(enc.name)" : "CSV · \(enc.name)")
        let crlf = data.prefix(64 * 1024).range(of: Data([0x0D, 0x0A])) != nil
        wb.csv = CSVFormat(delimiter: delim, encoding: enc.encoding, bom: enc.bomLength > 0, crlf: crlf)
        return wb
    }

    // MARK: XLSX

    public static func readXLSX(url: URL) throws -> Workbook {
        let rawParts: [String: Data]
        do {
            rawParts = try ArchiveReader.extractAll(url: url) { p in
                p == "xl/workbook.xml" || p == "xl/_rels/workbook.xml.rels" || p == "xl/sharedStrings.xml" ||
                    p == "xl/styles.xml" || p == "xl/theme/theme1.xml" || (p.hasPrefix("xl/worksheets/") && p.hasSuffix(".xml")) ||
                    // What is drawn over the cells: drawings, the charts and pictures they use, chart sheets.
                    p.hasPrefix("xl/drawings/") || p.hasPrefix("xl/charts/") || p.hasPrefix("xl/media/") ||
                    p.hasPrefix("xl/chartsheets/") || p.hasPrefix("xl/worksheets/_rels/")
            }
        } catch {
            throw SpreadsheetError(message: "无法读取工作簿：\(error.localizedDescription)")
        }
        // Some writers (the .NET Open XML SDK among them) put every element under a prefix
        // (<x:row>); the parsers read the plain names.
        let parts = rawParts.filter { !$0.key.hasPrefix("xl/media/") }.mapValues(XLSXNamespace.unprefixed)
        guard let wbData = parts["xl/workbook.xml"] else { throw SpreadsheetError(message: "不是有效的 xlsx 文件（缺少 workbook.xml）") }

        let rels = parts["xl/_rels/workbook.xml.rels"].map { RelsParser.parse($0) } ?? [:]
        let sheetsMeta = WorkbookParser.parse(wbData)
        let theme = parts["xl/theme/theme1.xml"].map { ThemeParser.parse($0) } ?? ThemeParser.officeDefault
        let stylesParser = parts["xl/styles.xml"].map { StylesParser.parsed($0, theme: theme) } ?? StylesParser(theme: theme)
        let styles = stylesParser.xfs.isEmpty ? [CellStyle()] : stylesParser.xfs
        // Rich-text runs name colours the same way cell styles do (theme / indexed / tint).
        let runColor: ([String: String]) -> RGBA? = { stylesParser.color($0) }
        let sharedTable = parts["xl/sharedStrings.xml"].map { SharedStringsParser.parse($0, color: runColor) } ?? (items: [], rich: [:])
        let shared = sharedTable.items
        let dateStyles = Set(styles.indices.filter { styles[$0].numberFormat.map(StylesParser.isDateFormat) ?? false })

        var sheets: [Sheet] = []
        for (i, meta) in sheetsMeta.enumerated() {
            var target = rels[meta.rid] ?? "worksheets/sheet\(i + 1).xml"
            if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
            target = target.replacingOccurrences(of: "xl/./", with: "xl/")
            guard let d = parts[target] else { continue }
            if target.hasPrefix("xl/chartsheets/") {
                var sh = Sheet(name: meta.name, rows: [])
                sh.isChartSheet = true
                sh.showGridLines = false
                sh.drawings = OfficeDrawings.sheetDrawings(sheetXML: d, sheetPath: target, theme: DrawingTheme(colors: theme), parts: rawParts)
                OfficeDrawings.fitChartSheet(&sh)
                sheets.append(sh)
                continue
            }
            let p = SheetXMLParser(shared: shared, sharedRich: sharedTable.rich, dateStyles: dateStyles, color: runColor)
            p.run(d)
            var sh = p.makeSheet(name: meta.name)
            sh.sourcePart = target
            sh.drawings = OfficeDrawings.sheetDrawings(sheetXML: d, sheetPath: target, theme: DrawingTheme(colors: theme), parts: rawParts)
            OfficeDrawings.makeRoom(for: &sh)
            sheets.append(sh)
        }
        if sheets.isEmpty {
            // Some writers omit rels; fall back to every worksheet in name order.
            for (k, d) in parts.filter({ $0.key.hasPrefix("xl/worksheets/") && !$0.key.contains("/_rels/") }).sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
                let p = SheetXMLParser(shared: shared, sharedRich: sharedTable.rich, dateStyles: dateStyles, color: runColor)
                p.run(d)
                var sh = p.makeSheet(name: (k as NSString).lastPathComponent.replacingOccurrences(of: ".xml", with: ""))
                sh.sourcePart = k
                sheets.append(sh)
            }
        }
        guard !sheets.isEmpty else { throw SpreadsheetError(message: "工作簿中没有工作表") }
        var wb = Workbook(sheets: sheets, source: "Excel 工作簿")
        wb.styles = styles
        // Data bars and colour scales are drawn; other rules (cell value, formula, icons) are not.
        if wb.sheets.contains(where: { $0.otherConditionalFormats > 0 }) {
            wb.notes.append("含按规则变色的条件格式，Loupe 只画数据条和色阶，其余可切换「原样」查看")
        }
        fillUncachedFormulas(&wb)
        return wb
    }

    /// The zoom Excel saved for the sheet a workbook opens on (percent), read from the first
    /// few KB of that sheet instead of parsing the workbook — for showing it as Excel would.
    public static func savedZoom(xlsx url: URL) -> Double? {
        guard let parts = try? ArchiveReader.extractAll(url: url, matching: { $0 == "xl/workbook.xml" || $0 == "xl/_rels/workbook.xml.rels" }),
              let wbData = parts["xl/workbook.xml"] else { return nil }
        let sheets = WorkbookParser.parse(wbData)
        let wbText = String(decoding: wbData.prefix(8192), as: UTF8.self)
        var active = 0
        if let r = wbText.range(of: #"activeTab="(\d+)""#, options: .regularExpression),
           let n = Int(wbText[r].filter(\.isNumber)) { active = n }
        guard sheets.indices.contains(active) else { return nil }
        let rels = parts["xl/_rels/workbook.xml.rels"].map { RelsParser.parse($0) } ?? [:]
        var target = rels[sheets[active].rid] ?? "worksheets/sheet\(active + 1).xml"
        if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
        guard let head = ArchiveReader.extractHead(url: url, matching: { $0 == target }, bytes: 16 << 10) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        guard let r = text.range(of: #"<(\w+:)?sheetView\b[^>]*\bzoomScale="(\d+)""#, options: .regularExpression) else { return nil }
        let tag = text[r]
        guard let z = tag.range(of: #"zoomScale="(\d+)""#, options: .regularExpression).flatMap({ Double(tag[$0].filter(\.isNumber)) }),
              z >= 10, z <= 400 else { return nil }
        return z
    }

    /// Files written by some tools (scripts, older apps) store formulas without cached results.
    /// Compute those with Loupe's own engine so the cells are not blank.
    public static func fillUncachedFormulas(_ wb: inout Workbook) {
        for si in wb.sheets.indices {
            let pending = wb.sheets[si].formulas.filter { k, _ in
                let (r, c) = (k / 16384, k % 16384)
                return wb.sheets[si].cell(r, c).isEmpty
            }.sorted { $0.key < $1.key }
            guard !pending.isEmpty, pending.count <= 200_000 else { continue }
            for (k, f) in pending {
                let (r, c) = (k / 16384, k % 16384)
                let v = FormulaEngine.evaluate(f, in: FormulaContext(workbook: wb, sheet: si)).cell
                while wb.sheets[si].rows.count <= r { wb.sheets[si].rows.append([]) }
                while wb.sheets[si].rows[r].count <= c { wb.sheets[si].rows[r].append(.empty) }
                wb.sheets[si].rows[r][c] = v
            }
            wb.sheets[si].columnCount = wb.sheets[si].rows.reduce(0) { max($0, $1.count) }
        }
    }

    // MARK: ODS

    public static func readODS(url: URL) throws -> Workbook {
        guard let (_, content) = ArchiveReader.extract(url: url, matching: { $0 == "content.xml" }, maxBytes: 512 << 20) else {
            throw SpreadsheetError(message: "不是有效的 ODS 文件（缺少 content.xml）")
        }
        let p = ODSParser()
        p.run(content)
        guard !p.sheets.isEmpty else { throw SpreadsheetError(message: "表格中没有工作表") }
        return Workbook(sheets: p.sheets, source: "OpenDocument 表格")
    }
}

// MARK: - XML parsers

/// Removes the prefix some writers give SpreadsheetML / relationship elements (`<x:row>` →
/// `<row>`), so the parsers below — which match plain element names — read those files too.
enum XLSXNamespace {
    static let namespaces = ["http://schemas.openxmlformats.org/spreadsheetml/2006/main",
                             "http://schemas.openxmlformats.org/package/2006/relationships"]

    static func unprefixed(_ d: Data) -> Data {
        let head = String(decoding: d.prefix(4096), as: UTF8.self)
        var prefixes: [String] = []
        for ns in namespaces {
            let pattern = #"xmlns:([A-Za-z_][\w.-]*)=""# + NSRegularExpression.escapedPattern(for: ns) + "\""
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                  let r = Range(m.range(at: 1), in: head) else { continue }
            prefixes.append(String(head[r]))
        }
        guard !prefixes.isEmpty else { return d }
        var text = String(decoding: d, as: UTF8.self)
        for p in prefixes {
            text = text.replacingOccurrences(of: "<\(p):", with: "<").replacingOccurrences(of: "</\(p):", with: "</")
        }
        return Data(text.utf8)
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]
    static func parse(_ d: Data) -> [String: String] {
        let p = RelsParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.map
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if name == "Relationship", let id = a["Id"], let t = a["Target"] { map[id] = t }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, rid: String)] = []
    static func parse(_ d: Data) -> [(name: String, rid: String)] {
        let p = WorkbookParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.sheets
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        guard name == "sheet" else { return }
        let rid = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value ?? ""
        if a["state"] == "veryHidden" { return }
        sheets.append((a["name"] ?? "Sheet\(sheets.count + 1)", rid))
    }
}

/// Collects the runs of a rich-text string (`<r><rPr>…</rPr><t>…</t></r>`), shared by the
/// shared-strings table and cells that hold their text inline.
struct RichRunReader {
    let color: ([String: String]) -> RGBA?
    private(set) var runs: [RichRun] = []
    private var props: RichRun?
    private(set) var hasRuns = false

    init(color: @escaping ([String: String]) -> RGBA?) { self.color = color }

    mutating func reset() { runs = []; props = nil; hasRuns = false }

    /// An element inside `<si>` / `<is>`.
    mutating func start(_ name: String, _ a: [String: String]) {
        func on() -> Bool { a["val"].map { $0 != "0" && $0 != "false" && $0 != "none" } ?? true }
        switch name {
        case "r": props = RichRun(text: ""); hasRuns = true
        case "b": props?.bold = on()
        case "i": props?.italic = on()
        case "u": props?.underline = on()
        case "strike": props?.strike = on()
        case "sz": props?.size = a["val"].flatMap(Double.init)
        case "color": props?.color = color(a)
        default: break
        }
    }

    /// Text of a `<t>`: goes to the current run (or a plain one, for `<si><t>` without runs).
    mutating func text(_ s: String) {
        if var p = props { p.text += s; props = p } else if let last = runs.indices.last, runs[last].isPlain { runs[last].text += s } else { runs.append(RichRun(text: s)) }
    }

    mutating func end(_ name: String) {
        if name == "r", let p = props { runs.append(p); props = nil }
    }

    /// The runs, when at least one carries its own formatting (otherwise the text is plain).
    var formatted: [RichRun]? { hasRuns && runs.contains { !$0.isPlain } ? runs : nil }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var items: [String] = []
    var rich: [Int: [RichRun]] = [:]
    private var current = ""
    private var inT = false, inPhonetic = false
    private var reader: RichRunReader
    init(color: @escaping ([String: String]) -> RGBA?) { reader = RichRunReader(color: color) }

    static func parse(_ d: Data, color: @escaping ([String: String]) -> RGBA?) -> (items: [String], rich: [Int: [RichRun]]) {
        let p = SharedStringsParser(color: color); let x = XMLParser(data: d); x.delegate = p; x.parse(); return (p.items, p.rich)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "si": current = ""; reader.reset()
        case "t": inT = true
        case "rPh": inPhonetic = true
        default: if !inPhonetic { reader.start(name, a) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if inT && !inPhonetic { current += s; reader.text(s) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "si":
            if let runs = reader.formatted { rich[items.count] = runs }
            items.append(current)
        case "t": inT = false
        case "rPh": inPhonetic = false
        default: if !inPhonetic { reader.end(name) }
        }
    }
}

/// Reads xl/theme/theme1.xml colour scheme (dk1, lt1, dk2, lt2, accent1…6, hlink, folHlink).
final class ThemeParser: NSObject, XMLParserDelegate {
    static let officeDefault: [RGBA] = ["000000", "FFFFFF", "44546A", "E7E6E6", "4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47", "0563C1", "954F72"].map { RGBA(hex: $0)! }
    private static let order = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]
    private var colors: [String: RGBA] = [:]
    private var current: String?
    private var inScheme = false

    static func parse(_ d: Data) -> [RGBA] {
        let p = ThemeParser(); let x = XMLParser(data: d); x.delegate = p; x.parse()
        return order.enumerated().map { p.colors[$0.element] ?? officeDefault[$0.offset] }
    }
    private func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        let n = local(name)
        if n == "clrScheme" { inScheme = true; return }
        guard inScheme else { return }
        if ThemeParser.order.contains(n) { current = n; return }
        guard let cur = current else { return }
        if n == "srgbClr", let v = a["val"] { colors[cur] = RGBA(hex: v) }
        if n == "sysClr", let v = a["lastClr"] { colors[cur] = RGBA(hex: v) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let n = local(name)
        if n == "clrScheme" { inScheme = false }
        if n == current { current = nil }
    }
}

/// Resolves styles.xml into one CellStyle per cellXfs entry.
final class StylesParser: NSObject, XMLParserDelegate {
    struct Font { var color: RGBA?; var bold = false, italic = false, underline = false, strike = false; var size: Double? }
    let theme: [RGBA]
    var numFmts: [Int: String] = [:]
    var fonts: [Font] = []
    var fills: [RGBA?] = []
    var borders: [(BorderSides, RGBA?)] = []
    var xfs: [CellStyle] = []
    var indexedOverride: [RGBA] = []

    private var section = ""
    private var font: Font?
    private var fill: RGBA?
    private var inFill = false
    private var patternSolid = false
    private var border: (BorderSides, RGBA?)?
    private var borderSide: BorderSides?
    private var xf: CellStyle?
    private var inCellXfs = false

    init(theme: [RGBA]) { self.theme = theme }

    static func parse(_ d: Data, theme: [RGBA]) -> [CellStyle] {
        let p = StylesParser(theme: theme); let x = XMLParser(data: d); x.delegate = p; x.parse()
        return p.xfs.isEmpty ? [CellStyle()] : p.xfs
    }

    /// The parser after reading styles.xml, so its colour lookup knows the file's own palette.
    static func parsed(_ d: Data, theme: [RGBA]) -> StylesParser {
        let p = StylesParser(theme: theme); let x = XMLParser(data: d); x.delegate = p; x.parse()
        return p
    }

    static func isDateFormat(_ code: String) -> Bool {
        let stripped = code.replacingOccurrences(of: #""[^"]*"|\\.|\[[^\]]*\]"#, with: "", options: .regularExpression).lowercased()
        if stripped == "general" || stripped.contains("0") || stripped.contains("#") { return false }
        return stripped.contains("y") || stripped.contains("d") || stripped.contains("m") || stripped.contains("h") || stripped.contains("s")
    }

    func color(_ a: [String: String]) -> RGBA? {
        var c: RGBA?
        if let rgb = a["rgb"] { c = RGBA(hex: rgb) }
        else if let t = a["theme"].flatMap(Int.init) {
            // Theme indices swap dark/light: 0=lt1, 1=dk1, 2=lt2, 3=dk2.
            let map = [1, 0, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11]
            if t < map.count { c = theme[map[t]] }
        } else if let i = a["indexed"].flatMap(Int.init) {
            let palette = indexedOverride.isEmpty ? RGBA.indexed : indexedOverride
            if i < palette.count { c = palette[i] } else if i == 64 { c = nil }   // 64 = system foreground
        } else if a["auto"] == "1" { c = nil }
        if let t = a["tint"].flatMap(Double.init), let base = c { c = base.tinted(t) }
        return c
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "numFmt": if let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] { numFmts[id] = code }
        case "fonts", "fills", "borders", "cellStyleXfs", "dxfs", "colors": section = name
        case "rgbColor": if section == "colors", let v = a["rgb"].flatMap(RGBA.init(hex:)) { indexedOverride.append(v) }
        case "cellXfs": inCellXfs = true; section = name
        case "font": if section == "fonts" { font = Font() }
        case "b": if font != nil { font?.bold = a["val"] != "0" && a["val"] != "false" }
        case "i": if font != nil { font?.italic = a["val"] != "0" && a["val"] != "false" }
        case "u": if font != nil { font?.underline = a["val"] != "none" }
        case "strike": if font != nil { font?.strike = a["val"] != "0" }
        case "sz": if font != nil { font?.size = a["val"].flatMap(Double.init) }
        case "color":
            if font != nil { font?.color = color(a) }
            else if var b = border, borderSide != nil {
                if b.1 == nil { b.1 = color(a) }
                border = b
            }
        case "fill": if section == "fills" { inFill = true; fill = nil; patternSolid = false }
        case "patternFill": if inFill { patternSolid = a["patternType"] != nil && a["patternType"] != "none" && a["patternType"] != "gray125" }
        case "fgColor": if inFill && patternSolid { fill = color(a) }
        case "bgColor": if inFill && patternSolid && fill == nil { fill = color(a) }
        case "border": if section == "borders" { border = ([], nil) }
        case "left", "right", "top", "bottom":
            if border != nil, let st = a["style"], st != "none" {
                borderSide = name == "left" ? .left : name == "right" ? .right : name == "top" ? .top : .bottom
                border?.0.insert(borderSide!)
            }
        case "xf":
            guard inCellXfs else { return }
            var st = CellStyle()
            let nf = a["numFmtId"].flatMap(Int.init) ?? 0
            if nf != 0 { st.numberFormat = numFmts[nf] ?? NumberFormat.builtin[nf] }
            if let f = a["fontId"].flatMap(Int.init), f < fonts.count, f != 0 || fonts[0].color != nil {
                let fo = fonts[f]
                st.fontColor = fo.color; st.bold = fo.bold; st.italic = fo.italic; st.underline = fo.underline; st.strike = fo.strike
                st.fontSize = fo.size
            }
            if let f = a["fillId"].flatMap(Int.init), f < fills.count { st.fill = fills[f] }
            if let b = a["borderId"].flatMap(Int.init), b < borders.count { st.borders = borders[b].0; st.borderColor = borders[b].1 }
            xf = st
        case "alignment":
            guard xf != nil else { return }
            switch a["horizontal"] {
            case "center", "centerContinuous", "distributed": xf?.hAlign = .center
            case "right": xf?.hAlign = .right
            case "left": xf?.hAlign = .left
            case "justify": xf?.hAlign = .justify
            case "fill": xf?.hAlign = .fill
            default: break
            }
            switch a["vertical"] { case "top": xf?.vAlign = .top; case "center": xf?.vAlign = .center; default: break }
            if a["wrapText"] == "1" || a["wrapText"] == "true" { xf?.wrap = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "font": if let f = font { fonts.append(f); font = nil }
        case "fill": if inFill { fills.append(fill); inFill = false }
        case "left", "right", "top", "bottom": borderSide = nil
        case "border": if let b = border { borders.append(b); border = nil }
        case "xf": if inCellXfs, let x = xf { xfs.append(x); xf = nil }
        case "cellXfs": inCellXfs = false; section = ""
        case "fonts", "fills", "borders", "cellStyleXfs", "dxfs", "colors": section = ""
        default: break
        }
    }
}

/// Streams a worksheet: <row><c r="B3" t="s" s="2"><f>…</f><v>…</v></c></row>.
final class SheetXMLParser: NSObject, XMLParserDelegate {
    let shared: [String]
    let dateStyles: Set<Int>
    var rows: [[CellValue]] = []
    var formulas: [Int: String] = [:]
    private var r = -1, c = 0
    private var type = "", style = 0
    private var value = "", formula = ""
    private var inV = false, inF = false, inIsT = false
    private var nextRow = 0, nextCol = 0
    var styleIDs: [Int: Int] = [:]
    var colWidths: [Int: Double] = [:]
    var rowHeights: [Int: Double] = [:]
    var customHeightRows = Set<Int>()
    var defaultRowHeight: Double?
    private var fType = "", fShared = ""
    private var sharedMasters: [String: (formula: String, r: Int, c: Int)] = [:]
    /// Slaves that appeared before their master. Resolved once the sheet is finished.
    private var pendingShared: [(si: String, r: Int, c: Int)] = []
    var hiddenRows = Set<Int>()
    var hiddenCols = Set<Int>()
    var merges: [MergeRange] = []
    var frozenRows = 0, frozenCols = 0
    var showGrid = true
    var zoomScale: Double = 100
    var defaultColWidth: Double?

    let sharedRich: [Int: [RichRun]]
    var richText: [Int: [RichRun]] = [:]
    private var inline: RichRunReader
    private var inIs = false
    private var conditional: ConditionalFormatReader

    init(shared: [String], sharedRich: [Int: [RichRun]] = [:], dateStyles: Set<Int>, color: @escaping ([String: String]) -> RGBA? = { _ in nil }) {
        self.shared = shared; self.sharedRich = sharedRich; self.dateStyles = dateStyles
        inline = RichRunReader(color: color)
        conditional = ConditionalFormatReader(color: color)
    }

    private func resolvePendingShared() {
        for item in pendingShared {
            guard let m = sharedMasters[item.si] else { continue }
            let shifted = FormulaRefs.shifted(m.formula, rows: item.r - m.r, cols: item.c - m.c)
            formulas[Sheet.key(item.r, item.c)] = "=" + shifted
        }
        pendingShared.removeAll()
    }

    func makeSheet(name: String) -> Sheet {
        resolvePendingShared()
        var s = Sheet(name: name, rows: rows, formulas: formulas)
        s.styleIDs = styleIDs
        s.columnWidths = colWidths
        s.rowHeights = rowHeights
        s.customHeightRows = customHeightRows
        s.defaultRowHeight = defaultRowHeight
        s.hiddenRows = hiddenRows
        s.hiddenColumns = hiddenCols
        s.merges = merges
        s.frozenRows = frozenRows
        s.frozenColumns = frozenCols
        s.showGridLines = showGrid
        s.zoomScale = zoomScale
        s.defaultColumnWidth = defaultColWidth
        s.richText = richText
        s.conditionalFormats = conditional.rules
        s.otherConditionalFormats = conditional.unsupported
        // Empty rows still covered by a merged area or sized by hand belong to the layout.
        // A merge that runs to the last Excel row must not materialise a million empty rows.
        let padCap = min(SpreadsheetReader.maxRows - 1, s.rows.count + SpreadsheetReader.maxLayoutPadding)
        let mergeEnd = merges.map(\.r1).max() ?? -1
        let heightEnd = customHeightRows.filter { $0 < s.rows.count + 64 }.max() ?? -1
        let lastLayoutRow = min(max(mergeEnd, heightEnd), padCap)
        if lastLayoutRow >= s.rows.count && lastLayoutRow < SpreadsheetReader.maxRows {
            let extra = lastLayoutRow + 1 - s.rows.count
            s.rows.append(contentsOf: Array(repeating: [], count: extra))
        }
        if let mc = merges.map(\.c1).max(), mc >= s.columnCount, mc < 16384 { s.columnCount = mc + 1 }
        // Styled-but-empty columns (e.g. a coloured band) still count as part of the sheet.
        let styledCols = styleIDs.keys.map { $0 % 16384 }.max().map { $0 + 1 } ?? 0
        s.columnCount = max(s.columnCount, min(styledCols, s.columnCount + 26))
        return s
    }

    func run(_ d: Data) { let x = XMLParser(data: d); x.delegate = self; x.parse() }

    static func parseRef(_ s: String) -> (Int, Int)? {
        let letters = s.prefix { $0.isLetter }
        guard let col = Sheet.columnIndex(String(letters)), let row = Int(s.dropFirst(letters.count)) else { return nil }
        return (row - 1, col)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if ConditionalFormatReader.handles(name) { conditional.start(name, a) }
        switch name {
        case "row":
            r = (a["r"].flatMap(Int.init) ?? (nextRow + 1)) - 1
            nextRow = r + 1
            nextCol = 0
            if let ht = a["ht"].flatMap(Double.init) {
                rowHeights[r] = ht
                if a["customHeight"] == "1" || a["customHeight"] == "true" { customHeightRows.insert(r) }
            }
            if a["hidden"] == "1" || a["hidden"] == "true" { hiddenRows.insert(r) }
        case "col":
            guard let lo = a["min"].flatMap(Int.init), let hi = a["max"].flatMap(Int.init), lo >= 1 else { return }
            let w = a["width"].flatMap(Double.init)
            let hidden = a["hidden"] == "1" || a["hidden"] == "true"
            for c in (lo - 1)...min(hi - 1, lo + 1024) {
                if let w { colWidths[c] = w }
                if hidden { hiddenCols.insert(c) }
            }
        case "mergeCell": if let ref = a["ref"], let m = MergeRange.parse(ref) { merges.append(m) }
        case "pane":
            if a["state"] == "frozen" || a["state"] == "frozenSplit" {
                frozenRows = Int(Double(a["ySplit"] ?? "0") ?? 0)
                frozenCols = Int(Double(a["xSplit"] ?? "0") ?? 0)
            }
        case "sheetView":
            if a["showGridLines"] == "0" || a["showGridLines"] == "false" { showGrid = false }
            if let z = a["zoomScale"].flatMap(Double.init), z >= 10, z <= 400 { zoomScale = z }
        case "sheetFormatPr":
            defaultColWidth = a["defaultColWidth"].flatMap(Double.init)
            defaultRowHeight = a["defaultRowHeight"].flatMap(Double.init)
        case "c":
            if let ref = a["r"], let (rr, cc) = SheetXMLParser.parseRef(ref) { r = rr; c = cc } else { c = nextCol }
            nextCol = c + 1
            type = a["t"] ?? "n"
            style = a["s"].flatMap(Int.init) ?? 0
            if style != 0 { styleIDs[Sheet.key(r, c)] = style }
            value = ""; formula = ""; fType = ""; fShared = ""
            inline.reset()
        case "is": inIs = true
        case "v": inV = true
        case "f":
            inF = true
            fType = a["t"] ?? ""
            fShared = a["si"] ?? ""
        case "t": inIsT = true
        default: if inIs { inline.start(name, a) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if inV { value += s } else if inF { formula += s } else if inIsT { value += s; if inIs { inline.text(s) } }
        else { conditional.characters(s) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if ConditionalFormatReader.handles(name) { conditional.end(name) }
        switch name {
        case "v": inV = false
        case "f": inF = false
        case "r", "rPr": if inIs { inline.end(name) }
        case "t": inIsT = false
        case "is": inIs = false
        case "c":
            guard r >= 0, r < SpreadsheetReader.maxRows, c >= 0, c < 16384 else { return }
            // A single cell a huge gap below the last row is dropped, not used to grow the sheet.
            if r > rows.count + SpreadsheetReader.maxLayoutPadding { return }
            // Text in mixed formats: from the shared table, or written inline.
            if type == "s", let i = Int(value), let runs = sharedRich[i] { richText[Sheet.key(r, c)] = runs }
            else if type == "inlineStr", let runs = inline.formatted { richText[Sheet.key(r, c)] = runs }
            let cell: CellValue
            switch type {
            case "s": cell = Int(value).flatMap { $0 < shared.count ? .text(shared[$0]) : nil } ?? .empty
            case "str", "inlineStr": cell = value.isEmpty ? .empty : .text(value)
            case "b": cell = .bool(value == "1")
            case "e": cell = .error(value)
            default:
                if let d = Double(value) { cell = dateStyles.contains(style) ? .date(d) : .number(d) }
                else { cell = value.isEmpty ? .empty : .text(value) }
            }
            while rows.count <= r { rows.append([]) }
            if !cell.isEmpty || !formula.isEmpty {
                while rows[r].count < c { rows[r].append(.empty) }
                if rows[r].count == c { rows[r].append(cell) } else { rows[r][c] = cell }
            }
            // Shared formulas: the first cell carries the text, the others repeat it shifted.
            if fType == "shared", !fShared.isEmpty {
                if !formula.isEmpty {
                    sharedMasters[fShared] = (formula, r, c)
                } else if let m = sharedMasters[fShared] {
                    formula = FormulaRefs.shifted(m.formula, rows: r - m.r, cols: c - m.c)
                } else {
                    pendingShared.append((fShared, r, c))
                }
            }
            if !formula.isEmpty {
                formulas[Sheet.key(r, c)] = "=" + formula
                if rows[r].count <= c { while rows[r].count < c { rows[r].append(.empty) }; rows[r].append(cell) }
            }
        default: break
        }
    }
}

/// OpenDocument spreadsheet content.xml, honouring repeated rows/columns.
private final class ODSParser: NSObject, XMLParserDelegate {
    var sheets: [Sheet] = []
    private var name = ""
    private var rows: [[CellValue]] = []
    private var row: [CellValue] = []
    private var rowRepeat = 1
    private var cellRepeat = 1
    private var cellValue: CellValue = .empty
    private var cellText = ""
    private var inCell = false
    private var textDepth = 0
    private var formulas: [Int: String] = [:]
    private var cellFormula: String?

    func run(_ d: Data) { let x = XMLParser(data: d); x.shouldProcessNamespaces = false; x.delegate = self; x.parse() }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch el {
        case "table:table": name = a["table:name"] ?? "Sheet\(sheets.count + 1)"; rows = []; formulas = [:]
        case "table:table-row":
            row = []
            rowRepeat = min(a["table:number-rows-repeated"].flatMap(Int.init) ?? 1, 10_000)
        case "table:table-cell", "table:covered-table-cell":
            inCell = true
            cellText = ""
            cellFormula = a["table:formula"]
            cellRepeat = min(a["table:number-columns-repeated"].flatMap(Int.init) ?? 1, 1024)
            switch a["office:value-type"] ?? "" {
            case "float", "currency", "percentage": cellValue = a["office:value"].flatMap(Double.init).map { .number($0) } ?? .empty
            case "date":
                if let s = a["office:date-value"] {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = s.contains("T") ? [.withFullDate, .withTime, .withColonSeparatorInTime] : [.withFullDate]
                    f.timeZone = TimeZone(identifier: "UTC")
                    cellValue = f.date(from: s).map { .date(CellValue.serial(from: $0)) } ?? .text(s)
                } else { cellValue = .empty }
            case "boolean": cellValue = .bool(a["office:boolean-value"] == "true")
            case "string": cellValue = .text("")
            default: cellValue = .empty
            }
        case "text:p": if inCell { if !cellText.isEmpty { cellText += "\n" }; textDepth += 1 }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { if inCell && textDepth > 0 { cellText += s } }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        switch el {
        case "text:p": textDepth = max(0, textDepth - 1)
        case "table:table-cell", "table:covered-table-cell":
            inCell = false
            var v = cellValue
            if case .text = v { v = .text(cellText) }
            if case .empty = v, !cellText.isEmpty { v = .text(cellText) }
            if let f = cellFormula { formulas[Sheet.key(rows.count, row.count)] = f.replacingOccurrences(of: "of:", with: "") }
            for _ in 0..<cellRepeat { row.append(v) }
        case "table:table-row":
            while let last = row.last, last.isEmpty { row.removeLast() }
            for _ in 0..<rowRepeat where rows.count < SpreadsheetReader.maxRows { rows.append(row) }
        case "table:table":
            while let last = rows.last, last.isEmpty { rows.removeLast() }
            sheets.append(Sheet(name: name, rows: rows, formulas: formulas))
        default: break
        }
    }
}
