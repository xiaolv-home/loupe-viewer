import Foundation

/// A column filter. Rules combine with AND across columns.
public enum FilterRule: Sendable, Equatable {
    case values(Set<String>)
    case contains(String)
    case notContains(String)
    case equals(String)
    case greater(Double)
    case less(Double)
    case between(Double, Double)
    case blank
    case notBlank

    public func matches(_ v: CellValue) -> Bool {
        let s = v.display
        switch self {
        case .values(let set): return set.contains(s)
        case .contains(let t): return s.localizedCaseInsensitiveContains(t)
        case .notContains(let t): return !s.localizedCaseInsensitiveContains(t)
        case .equals(let t): return s.compare(t, options: [.caseInsensitive]) == .orderedSame
        case .greater(let x): return (v.number ?? -.infinity) > x
        case .less(let x): return (v.number ?? .infinity) < x
        case .between(let a, let b): if let n = v.number { return n >= a && n <= b }; return false
        case .blank: return v.isEmpty
        case .notBlank: return !v.isEmpty
        }
    }

    public var summary: String {
        switch self {
        case .values(let s): return "\(s.count) 个值"
        case .contains(let t): return "包含「\(t)」"
        case .notContains(let t): return "不包含「\(t)」"
        case .equals(let t): return "等于「\(t)」"
        case .greater(let x): return "> \(CellValue.format(x))"
        case .less(let x): return "< \(CellValue.format(x))"
        case .between(let a, let b): return "\(CellValue.format(a)) ~ \(CellValue.format(b))"
        case .blank: return "为空"
        case .notBlank: return "非空"
        }
    }
}

/// View state over a sheet: which rows show, in what order. The sheet itself is never modified.
public struct SheetQuery: Sendable {
    /// Row used for column captions (nil = none). Rows above it are pinned at the top,
    /// shown as-is and never filtered or sorted (e.g. a report title above a frozen header).
    public var headerRowIndex: Int? = 0
    public var headerRow: Bool {
        get { headerRowIndex != nil }
        set { headerRowIndex = newValue ? (headerRowIndex ?? 0) : nil }
    }
    public var filters: [Int: FilterRule] = [:]
    public var sortColumn: Int?
    public var ascending = true
    public var hiddenRows: Set<Int> = []
    public var hiddenColumns: Set<Int> = []

    public init() {}

    public var firstDataRow: Int { headerRowIndex.map { $0 + 1 } ?? 0 }
    /// Rows that stay at the top, untouched by filters and sorting: the header row and anything above it.
    public var pinnedRows: [Int] { headerRowIndex.map { Array(0...$0) } ?? [] }
    public var isFiltered: Bool { !filters.isEmpty || !hiddenRows.isEmpty }

    public func visibleRows(in sheet: Sheet) -> [Int] {
        guard sheet.rows.count > firstDataRow else { return [] }
        var rows = Array(firstDataRow..<sheet.rows.count).filter { r in
            !hiddenRows.contains(r) && filters.allSatisfy { $0.value.matches(sheet.cell(r, $0.key)) }
        }
        if let c = sortColumn {
            let keyed = rows.map { (r: $0, v: sheet.cell($0, c)) }
            rows = keyed.sorted { a, b in
                // Blanks always last; numbers before text; stable by row index.
                if a.v.isEmpty != b.v.isEmpty { return !a.v.isEmpty }
                let x = a.v.number, y = b.v.number
                // Numbers before text regardless of direction; direction applies within a type.
                if (x == nil) != (y == nil) { return x != nil }
                var cmp: ComparisonResult
                if let x, let y { cmp = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame) }
                else { cmp = a.v.display.compare(b.v.display, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "zh_CN")) }
                if cmp == .orderedSame { return a.r < b.r }
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }.map(\.r)
        }
        return pinnedRows.filter { !hiddenRows.contains($0) && $0 < sheet.rows.count } + rows
    }

    /// Distinct display values of a column (for the filter list), most frequent first.
    public func distinctValues(in sheet: Sheet, column: Int, limit: Int = 2000) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for r in firstDataRow..<max(firstDataRow, sheet.rows.count) { counts[sheet.cell(r, column).display, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .prefix(limit).map { ($0.key, $0.value) }
    }
}

public struct SelectionStats: Sendable, Equatable {
    public var cells = 0
    public var nonEmpty = 0
    public var numeric = 0
    public var sum = 0.0
    public var min: Double?
    public var max: Double?
    public var average: Double? { numeric > 0 ? sum / Double(numeric) : nil }

    public init(_ values: [CellValue]) {
        cells = values.count
        for v in values {
            if !v.isEmpty { nonEmpty += 1 }
            let n: Double?
            switch v {
            case .number(let d), .date(let d): n = d
            case .text(let t): n = CellValue.parseNumber(t)
            default: n = nil
            }
            guard let n else { continue }
            numeric += 1
            sum += n
            min = Swift.min(min ?? n, n)
            max = Swift.max(max ?? n, n)
        }
    }
}
