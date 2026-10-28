import Foundation

/// Turns a ChartSpec into the numbers to draw: each reference is read from the data source
/// (the workbook the chart sits in) when it can be followed, else from the cached copy.
/// Scripts such as openpyxl write charts with references only, so the cache alone is often empty.
extension ChartSpec {
    public func resolved(using source: ChartDataSource?) -> ResolvedChart {
        var index = 0
        var plots: [ResolvedPlot] = []
        for p in layeredPlots() {
            var series: [ResolvedSeries] = []
            for s in p.series {
                let cats = labels(s.categories, source)
                let numericX = p.kind == .scatter || p.kind == .bubble ? numbers(s.categories, source) : nil
                let vals = numbers(s.values, source) ?? []
                let name = s.name.flatMap { resolveText($0, source) } ?? "系列\(index + 1)"
                series.append(ResolvedSeries(
                    series: s, name: name, categories: cats, values: vals,
                    xValues: numericX.flatMap { xs in xs.contains { $0 != nil } ? xs : nil },
                    sizes: numbers(s.bubbleSizes, source),
                    numberFormat: s.values?.numberFormat ?? formatOf(s.values, source),
                    index: index))
                index += 1
            }
            let longest = series.map(\.categories).max { $0.count < $1.count } ?? []
            let count = series.map(\.values.count).max() ?? 0
            let categories = longest.isEmpty ? (0..<count).map { String($0 + 1) } : longest
            plots.append(ResolvedPlot(plot: p, series: series, categories: categories))
        }
        var title: String?
        if let t = self.title {
            title = resolveText(t, source)
            // A title with no text of its own: Excel shows the series name for a single series.
            if title == nil || title?.isEmpty == true {
                let all = plots.flatMap(\.series)
                title = all.count == 1 ? all[0].name : "图表标题"
            }
        } else if !autoTitleDeleted, plots.count == 1, plots[0].series.count == 1, plots[0].plot.kind == .pie || plots[0].plot.kind == .doughnut {
            title = plots[0].series[0].name
        }
        return ResolvedChart(spec: self, title: title, plots: plots)
    }

    /// Bars and areas behind lines, as Excel layers a combination chart.
    private func layeredPlots() -> [ChartPlot] {
        let rank: [ChartKind: Int] = [.area: 0, .bar: 1, .pie: 1, .doughnut: 1, .radar: 1, .bubble: 2, .line: 3, .scatter: 3]
        return plots.enumerated().sorted { (rank[$0.element.kind] ?? 1, $0.offset) < (rank[$1.element.kind] ?? 1, $1.offset) }.map(\.element)
    }

    private func cells(_ v: ChartValues?, _ source: ChartDataSource?) -> [ChartCell]? {
        guard let ref = v?.reference, !ref.isEmpty, let grid = source?.chartCells(ref) else { return nil }
        // A block of several rows and columns is read row by row (Excel does the same for a
        // single series spread over a rectangle).
        return grid.flatMap { $0 }
    }

    func numbers(_ v: ChartValues?, _ source: ChartDataSource?) -> [Double?]? {
        guard let v else { return nil }
        if let c = cells(v, source) { return c.map(\.number) }
        let n = max(v.cachedCount, (v.cachedNumbers.keys.max() ?? -1) + 1)
        return (0..<n).map { v.cachedNumbers[$0] }
    }

    func labels(_ v: ChartValues?, _ source: ChartDataSource?) -> [String] {
        guard let v else { return [] }
        if let ref = v.reference, !ref.isEmpty, let grid = source?.chartCells(ref) {
            // Multi-level categories (several columns): join the levels of each row.
            let rows = grid.count, cols = grid.map(\.count).max() ?? 0
            if rows > 1 && cols > 1 && rows >= cols {
                return grid.map { $0.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
            }
            return grid.flatMap { $0 }.map(\.text)
        }
        let n = max(v.cachedCount, (v.cachedText.keys.max() ?? -1) + 1)
        return (0..<n).map { i in
            if let t = v.cachedText[i] {
                if v.numeric, let d = v.cachedNumbers[i] { return NumberFormat.format(.number(d), code: v.numberFormat).text }
                return t
            }
            return ""
        }
    }

    private func formatOf(_ v: ChartValues?, _ source: ChartDataSource?) -> String? {
        guard let ref = v?.reference, let grid = source?.chartCells(ref) else { return nil }
        return grid.lazy.flatMap { $0 }.first { $0.number != nil }?.numberFormat
    }

    func resolveText(_ t: ChartText, _ source: ChartDataSource?) -> String? {
        if let ref = t.reference, let grid = source?.chartCells(ref) {
            let s = grid.flatMap { $0 }.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            if !s.isEmpty { return s }
        }
        return t.text
    }
}

/// A chart reference split into sheet and cell ranges: `'My Sheet'!$A$2:$A$9`,
/// `Sheet1!$C$1`, `(Sheet1!$A$1:$A$3,Sheet1!$C$1:$C$3)`, `Sheet1!$A:$A`.
public struct ChartReference: Sendable, Equatable {
    public struct Area: Sendable, Equatable {
        public var sheet: String?
        public var r0: Int, c0: Int, r1: Int, c1: Int
    }
    public var areas: [Area]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("=") { s.removeFirst() }
        if s.hasPrefix("(") && s.hasSuffix(")") { s = String(s.dropFirst().dropLast()) }
        var parts: [String] = []
        var current = "", quoted = false
        for ch in s {
            if ch == "'" { quoted.toggle() }
            if ch == "," && !quoted { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        var areas: [Area] = []
        for p in parts {
            guard let a = ChartReference.area(p) else { return nil }
            areas.append(a)
        }
        guard !areas.isEmpty else { return nil }
        self.areas = areas
    }

    static func area(_ text: String) -> Area? {
        var sheet: String?
        var range = text
        if let bang = text.lastIndex(of: "!") {
            var name = String(text[..<bang])
            if name.hasPrefix("'") && name.hasSuffix("'") && name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            // `[1]Sheet1` — an external workbook: not ours to read.
            if name.hasPrefix("[") { return nil }
            sheet = name
            range = String(text[text.index(after: bang)...])
        }
        let ends = range.replacingOccurrences(of: "$", with: "").split(separator: ":").map(String.init)
        guard ends.count == 1 || ends.count == 2, let a = cell(ends[0]) else { return nil }
        let b = ends.count == 2 ? (cell(ends[1]) ?? a) : a
        // A missing row or column (whole column `A:A`, whole row `3:3`) spans everything.
        let r0 = min(a.row ?? 0, b.row ?? 0), r1 = max(a.row ?? huge, b.row ?? huge)
        let c0 = min(a.col ?? 0, b.col ?? 0), c1 = max(a.col ?? 16383, b.col ?? 16383)
        return Area(sheet: sheet, r0: r0, c0: c0, r1: r1, c1: c1)
    }

    static let huge = 1_048_575

    /// "B7" → row 6, column 1; "B" → column only; "7" → row only.
    static func cell(_ s: String) -> (row: Int?, col: Int?)? {
        let letters = s.prefix { $0.isLetter }
        let digits = s.dropFirst(letters.count)
        guard !s.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let col = letters.isEmpty ? nil : Sheet.columnIndex(String(letters))
        if !letters.isEmpty && col == nil { return nil }
        let row = digits.isEmpty ? nil : Int(digits).map { $0 - 1 }
        if let r = row, r < 0 { return nil }
        return (row, col)
    }
}

/// A workbook feeds its own charts.
extension Workbook: ChartDataSource {
    public func chartCells(_ reference: String) -> [[ChartCell]]? {
        guard let ref = ChartReference(reference) else { return nil }
        var out: [[ChartCell]] = []
        for a in ref.areas {
            let si: Int
            if let name = a.sheet {
                guard let i = sheetIndex(named: name) else { return nil }
                si = i
            } else {
                si = 0
            }
            let sh = sheets[si]
            // Whole columns / rows stop at the last cell in use.
            let r1 = min(a.r1, max(0, sh.rows.count - 1)), c1 = min(a.c1, max(0, sh.columnCount - 1))
            guard a.r0 <= r1, a.c0 <= c1 else { continue }
            for r in a.r0...r1 {
                var row: [ChartCell] = []
                for c in a.c0...c1 {
                    let v = sh.cell(r, c)
                    let f = formatted(si, r, c)
                    row.append(ChartCell(number: v.strictNumber, text: f.text, numberFormat: style(si, r, c)?.numberFormat))
                }
                out.append(row)
            }
        }
        return out
    }
}
