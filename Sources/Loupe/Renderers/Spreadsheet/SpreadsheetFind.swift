import AppKit
import LoupeCore

/// Find in the visible cells.
extension SpreadsheetRenderer {
    // MARK: Find

    func recomputeMatches() {
        matchKeys = []
        matchList = []
        matchCursor = -1
        let q = searchText.trimmingCharacters(in: .whitespaces)
        matchQuery = q
        guard !q.isEmpty else { searchInfo = ""; return }
        let cols = layout.cols
        for (vr, r) in visible.enumerated() {
            for c in cols where workbook.formatted(sheetIndex, r, c).text.localizedCaseInsensitiveContains(q) || sheet.cell(r, c).display.localizedCaseInsensitiveContains(q) {
                matchKeys.insert(Sheet.key(r, c))
                matchList.append(GridPoint(row: vr, col: c))
                if matchList.count >= 100_000 { break }
            }
        }
        searchInfo = matchList.isEmpty ? "无结果" : "\(Fmt.number(matchList.count)) 处"
    }

    /// Return in the find field: a new query searches and jumps to the first hit; the same query
    /// steps to the next one (⇧Return to the previous), like Find in any Mac app.
    func runSearch(backwards: Bool = false) {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q == matchQuery && !matchList.isEmpty {
            findNext(backwards ? -1 : 1)
            return
        }
        recomputeMatches()
        grid.redrawAll()
        // Start from the active cell, so the first jump lands on the next hit below it.
        if let i = matchList.firstIndex(where: { $0.row > active.row || ($0.row == active.row && (layout.position(of: $0.col) ?? 0) >= (layout.position(of: active.col) ?? 0)) }) {
            matchCursor = i - 1
        }
        findNext(1)
    }

    func findNext(_ d: Int) {
        guard !matchList.isEmpty else { return }
        matchCursor = (matchCursor + d + matchList.count) % matchList.count
        let p = matchList[matchCursor]
        gridSelect([GridRect(p, p)], active: p, anchor: p)
        grid.scrollTo(row: p.row, col: p.col)
        searchInfo = "\(matchCursor + 1) / \(Fmt.number(matchList.count))"
    }
}
