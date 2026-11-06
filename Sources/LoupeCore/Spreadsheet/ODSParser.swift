import Foundation

/// OpenDocument spreadsheet content.xml, honouring repeated rows/columns.
final class ODSParser: NSObject, XMLParserDelegate {
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
                } else {
                    cellValue = .empty
                }
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
