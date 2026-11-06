import Foundation

public struct SpreadsheetError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// Converts table files into Perlustra's Workbook model.
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
        var wb = Workbook(
            sheets: [Sheet(name: url.deletingPathExtension().lastPathComponent, rows: cells)],
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
                p == "xl/workbook.xml" || p == "xl/_rels/workbook.xml.rels" || p == "xl/sharedStrings.xml" || p == "xl/styles.xml" || p == "xl/theme/theme1.xml"
                    || (p.hasPrefix("xl/worksheets/") && p.hasSuffix(".xml"))
                    // What is drawn over the cells: drawings, the charts and pictures they use, chart sheets.
                    || p.hasPrefix("xl/drawings/") || p.hasPrefix("xl/charts/") || p.hasPrefix("xl/media/") || p.hasPrefix("xl/chartsheets/")
                    || p.hasPrefix("xl/worksheets/_rels/")
            }
        } catch {
            throw SpreadsheetError(message: "无法读取工作簿：\(error.localizedDescription)")
        }
        // Some writers (the .NET Open XML SDK among them) put every element under a prefix
        // (<x:row>); the parsers read the plain names.
        let parts = rawParts.filter { !$0.key.hasPrefix("xl/media/") }.mapValues(XLSXNamespace.unprefixed)
        guard let wbData = parts["xl/workbook.xml"] else { throw SpreadsheetError(message: "不是有效的 xlsx 文件（缺少 workbook.xml）") }

        let rels = parts["xl/_rels/workbook.xml.rels"].map { RelsParser.parse($0) } ?? [:]
        let book = WorkbookParser.parsed(wbData)
        let sheetsMeta = book.sheets
        let theme = parts["xl/theme/theme1.xml"].map { ThemeParser.parse($0) } ?? ThemeParser.officeDefault
        let stylesParser = parts["xl/styles.xml"].map { StylesParser.parsed($0, theme: theme) } ?? StylesParser(theme: theme)
        let styles = stylesParser.xfs.isEmpty ? [CellStyle()] : stylesParser.xfs
        // Rich-text runs name colours the same way cell styles do (theme / indexed / tint).
        let runColor: ([String: String]) -> RGBA? = { stylesParser.color($0) }
        let sharedTable = parts["xl/sharedStrings.xml"].map { SharedStringsParser.parse($0, color: runColor) } ?? (items: [], rich: [:])
        let shared = sharedTable.items
        let dateStyles = Set(styles.indices.filter { styles[$0].numberFormat.map(StylesParser.isDateFormat) ?? false })

        var sheets: [Sheet] = []
        var active = 0
        for (i, meta) in sheetsMeta.enumerated() {
            if i == book.activeTab { active = sheets.count }
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
                sh.isHidden = meta.hidden
                sheets.append(sh)
                continue
            }
            let p = SheetXMLParser(shared: shared, sharedRich: sharedTable.rich, dateStyles: dateStyles, color: runColor)
            p.run(d)
            var sh = p.makeSheet(name: meta.name)
            sh.sourcePart = target
            sh.drawings = OfficeDrawings.sheetDrawings(sheetXML: d, sheetPath: target, theme: DrawingTheme(colors: theme), parts: rawParts)
            OfficeDrawings.makeRoom(for: &sh)
            sh.isHidden = meta.hidden
            sheets.append(sh)
        }
        if sheets.isEmpty {
            // Some writers omit rels; fall back to every worksheet in name order.
            for (k, d) in parts.filter({ $0.key.hasPrefix("xl/worksheets/") && !$0.key.contains("/_rels/") }).sorted(by: {
                $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }) {
                let p = SheetXMLParser(shared: shared, sharedRich: sharedTable.rich, dateStyles: dateStyles, color: runColor)
                p.run(d)
                var sh = p.makeSheet(name: (k as NSString).lastPathComponent.replacingOccurrences(of: ".xml", with: ""))
                sh.sourcePart = k
                sheets.append(sh)
            }
        }
        guard !sheets.isEmpty else { throw SpreadsheetError(message: "工作簿中没有工作表") }
        var wb = Workbook(sheets: sheets, source: "Excel 工作簿")
        wb.activeSheet = sheets.indices.contains(active) ? active : 0
        wb.styles = styles
        // Data bars and colour scales are drawn; other rules (cell value, formula, icons) are not.
        if wb.sheets.contains(where: { $0.otherConditionalFormats > 0 }) {
            wb.notes.append("含按规则变色的条件格式，Perlustra 只画数据条和色阶，其余可切换「原样」查看")
        }
        fillUncachedFormulas(&wb)
        return wb
    }

    /// The zoom Excel saved for the sheet a workbook opens on (percent), read from the first
    /// few KB of that sheet instead of parsing the workbook — for showing it as Excel would.
    public static func savedZoom(xlsx url: URL) -> Double? {
        guard let parts = try? ArchiveReader.extractAll(url: url, matching: { $0 == "xl/workbook.xml" || $0 == "xl/_rels/workbook.xml.rels" }),
            let wbData = parts["xl/workbook.xml"]
        else { return nil }
        let book = WorkbookParser.parsed(wbData)
        let sheets = book.sheets, active = book.activeTab
        guard sheets.indices.contains(active) else { return nil }
        let rels = parts["xl/_rels/workbook.xml.rels"].map { RelsParser.parse($0) } ?? [:]
        var target = rels[sheets[active].rid] ?? "worksheets/sheet\(active + 1).xml"
        if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
        guard let head = ArchiveReader.extractHead(url: url, matching: { $0 == target }, bytes: 16 << 10) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        guard let r = text.range(of: #"<(\w+:)?sheetView\b[^>]*\bzoomScale="(\d+)""#, options: .regularExpression) else { return nil }
        let tag = text[r]
        guard let z = tag.range(of: #"zoomScale="(\d+)""#, options: .regularExpression).flatMap({ Double(tag[$0].filter(\.isNumber)) }),
            z >= 10, z <= 400
        else { return nil }
        return z
    }

    /// Files written by some tools (scripts, older apps) store formulas without cached results.
    /// Compute those with Perlustra's own engine so the cells are not blank.
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
    static let namespaces = [
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
        "http://schemas.openxmlformats.org/package/2006/relationships",
    ]

    static func unprefixed(_ d: Data) -> Data {
        let head = String(decoding: d.prefix(4096), as: UTF8.self)
        var prefixes: [String] = []
        for ns in namespaces {
            let pattern = #"xmlns:([A-Za-z_][\w.-]*)=""# + NSRegularExpression.escapedPattern(for: ns) + "\""
            guard let re = try? NSRegularExpression(pattern: pattern),
                let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                let r = Range(m.range(at: 1), in: head)
            else { continue }
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
