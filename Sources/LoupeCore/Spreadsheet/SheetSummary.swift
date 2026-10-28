import Foundation

/// Group-by summaries (a small pivot table), computed exactly — so totals the AI reports come
/// from the data, not from the model's arithmetic.
public enum SheetSummary {
    public enum Aggregate: String, Sendable, CaseIterable {
        case sum, count, average, max, min, distinct

        public var title: String {
            switch self {
            case .sum: return "合计"
            case .count: return "行数"
            case .average: return "平均"
            case .max: return "最大"
            case .min: return "最小"
            case .distinct: return "不同值个数"
            }
        }
    }

    /// One row per distinct combination of the group columns (in order of first appearance,
    /// or by the first value column descending when `sortDescending`), then a 总计 row.
    /// `rows` are the data rows to include (already filtered).
    public static func groupBy(_ sheet: Sheet, rows: [Int], header: Int?, groupColumns: [Int], valueColumns: [Int],
                               aggregate: Aggregate, sortDescending: Bool = true) -> [[CellValue]] {
        func name(_ c: Int) -> String {
            if let h = header { let t = sheet.cell(h, c).display; if !t.isEmpty { return t } }
            return Sheet.columnName(c) + "列"
        }
        struct Acc { var sum = 0.0; var n = 0; var count = 0; var mx = -Double.infinity; var mn = Double.infinity; var seen = Set<String>() }
        var order: [[String]] = []
        var groups: [[String]: [Acc]] = [:]
        var total = [Acc](repeating: Acc(), count: max(1, valueColumns.count))
        let values = valueColumns.isEmpty ? [-1] : valueColumns

        func add(_ a: inout Acc, _ v: CellValue) {
            a.count += v.isEmpty ? 0 : 1
            if !v.isEmpty { a.seen.insert(v.display) }
            if let d = v.strictNumber {
                a.sum += d; a.n += 1
                a.mx = Swift.max(a.mx, d); a.mn = Swift.min(a.mn, d)
            }
        }

        for r in rows {
            let key = groupColumns.map { sheet.cell(r, $0).display }
            if groups[key] == nil { groups[key] = [Acc](repeating: Acc(), count: values.count); order.append(key) }
            for (i, c) in values.enumerated() {
                let v: CellValue = c < 0 ? .number(1) : sheet.cell(r, c)
                add(&groups[key]![i], v)
                add(&total[i], v)
            }
        }

        // Sums of decimals pick up binary noise (…78 → …7799999998); round it away.
        func tidy(_ d: Double) -> Double { abs(d) < 1e12 ? (d * 1e8).rounded() / 1e8 : d }
        func result(_ a: Acc) -> CellValue {
            switch aggregate {
            case .sum: return .number(tidy(a.sum))
            case .count: return .number(Double(a.count))
            case .average: return a.n == 0 ? .empty : .number(tidy(a.sum / Double(a.n)))
            case .max: return a.n == 0 ? .empty : .number(a.mx)
            case .min: return a.n == 0 ? .empty : .number(a.mn)
            case .distinct: return .number(Double(a.seen.count))
            }
        }

        var keys = order
        if sortDescending, aggregate != .min {
            keys.sort { (result(groups[$0]![0]).number ?? 0) > (result(groups[$1]![0]).number ?? 0) }
        }
        let headerRow: [CellValue] = groupColumns.map { .text(name($0)) }
            + values.map { .text($0 < 0 ? aggregate.title : "\(name($0))（\(aggregate.title)）") }
        var out: [[CellValue]] = [headerRow]
        for k in keys {
            out.append(k.map { CellValue.text($0) } + groups[k]!.map(result))
        }
        if !groupColumns.isEmpty {
            out.append([.text("总计")] + Array(repeating: CellValue.empty, count: groupColumns.count - 1) + total.map(result))
        }
        return out
    }

    /// Tab-separated text of a table (what the model reads back).
    public static func tsv(_ rows: [[CellValue]], limit: Int = 500) -> String {
        var lines = rows.prefix(limit).map { $0.map { $0.display.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
        if rows.count > limit { lines.append("…（共 \(rows.count) 行，只列出前 \(limit) 行）") }
        return lines.joined(separator: "\n")
    }
}
