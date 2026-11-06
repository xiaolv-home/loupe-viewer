import Foundation

final class RelsParser: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]
    static func parse(_ d: Data) -> [String: String] {
        let p = RelsParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.map
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if name == "Relationship", let id = a["Id"], let t = a["Target"] { map[id] = t }
    }
}

final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Entry { var name: String; var rid: String; var hidden: Bool }
    var sheets: [Entry] = []
    /// Index into every sheet of the file, hidden ones included.
    var activeTab = 0
    static func parsed(_ d: Data) -> WorkbookParser {
        let p = WorkbookParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if name == "workbookView", let n = a["activeTab"].flatMap(Int.init) { activeTab = n; return }
        guard name == "sheet" else { return }
        let rid = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value ?? ""
        let state = a["state"] ?? "visible"
        sheets.append(Entry(name: a["name"] ?? "Sheet\(sheets.count + 1)", rid: rid, hidden: state == "hidden" || state == "veryHidden"))
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
        if var p = props {
            p.text += s; props = p
        } else if let last = runs.indices.last, runs[last].isPlain {
            runs[last].text += s
        } else {
            runs.append(RichRun(text: s))
        }
    }

    mutating func end(_ name: String) {
        if name == "r", let p = props { runs.append(p); props = nil }
    }

    /// The runs, when at least one carries its own formatting (otherwise the text is plain).
    var formatted: [RichRun]? { hasRuns && runs.contains { !$0.isPlain } ? runs : nil }
}

final class SharedStringsParser: NSObject, XMLParserDelegate {
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
    static let officeDefault: [RGBA] = ["000000", "FFFFFF", "44546A", "E7E6E6", "4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47", "0563C1", "954F72"]
        .map { RGBA(hex: $0)! }
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
        if let rgb = a["rgb"] {
            c = RGBA(hex: rgb)
        } else if let t = a["theme"].flatMap(Int.init) {
            // Theme indices swap dark/light: 0=lt1, 1=dk1, 2=lt2, 3=dk2.
            let map = [1, 0, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11]
            if t < map.count { c = theme[map[t]] }
        } else if let i = a["indexed"].flatMap(Int.init) {
            let palette = indexedOverride.isEmpty ? RGBA.indexed : indexedOverride
            if i < palette.count { c = palette[i] } else if i == 64 { c = nil }  // 64 = system foreground
        } else if a["auto"] == "1" {
            c = nil
        }
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
            if font != nil {
                font?.color = color(a)
            } else if var b = border, borderSide != nil {
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
            switch a["vertical"] {
            case "top": xf?.vAlign = .top;
            case "center": xf?.vAlign = .center;
            default: break
            }
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
