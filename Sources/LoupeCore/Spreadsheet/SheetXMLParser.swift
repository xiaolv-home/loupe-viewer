import Foundation

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
        if inV { value += s } else if inF { formula += s } else if inIsT { value += s; if inIs { inline.text(s) } } else { conditional.characters(s) }
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
            if type == "s", let i = Int(value), let runs = sharedRich[i] {
                richText[Sheet.key(r, c)] = runs
            } else if type == "inlineStr", let runs = inline.formatted {
                richText[Sheet.key(r, c)] = runs
            }
            let cell: CellValue
            switch type {
            case "s": cell = Int(value).flatMap { $0 < shared.count ? .text(shared[$0]) : nil } ?? .empty
            case "str", "inlineStr": cell = value.isEmpty ? .empty : .text(value)
            case "b": cell = .bool(value == "1")
            case "e": cell = .error(value)
            default:
                if let d = Double(value) { cell = dateStyles.contains(style) ? .date(d) : .number(d) } else { cell = value.isEmpty ? .empty : .text(value) }
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
