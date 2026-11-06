import AppKit
import SwiftUI
import LoupeCore
import Quartz

/// The grid's questions and clicks, and what a new selection does to the formula bar.
extension SpreadsheetRenderer {
    // MARK: GridViewOwner

    var gridLayout: GridLayout { layout }
    var gridGutterDigits: Int { String(max(1, sheet.rows.count)).count }

    func gridSelection() -> (rects: [GridRect], active: GridPoint, anchor: GridPoint) { (rects, active, anchor) }

    func gridSelect(_ r: [GridRect], active a: GridPoint, anchor an: GridPoint) {
        // Like Excel, a selection always covers merged areas whole: clicking (or dragging a
        // little) inside one selects the entire area, and the active cell is its top-left.
        let r = r.map(expandedToMerges)
        let a = mergeArea(row: a.row, col: a.col)?.topLeft ?? a
        let an = mergeArea(row: an.row, col: an.col)?.topLeft ?? an
        // Redraw what the old and the new selection cover.
        var dirtyRect = NSRect.null
        for g in rects + r { if let rr = layout.rect(g) { dirtyRect = dirtyRect.union(rr) } }
        for p in [active, a] { if let rr = cellArea(row: p.row, col: p.col) { dirtyRect = dirtyRect.union(rr) } }
        rects = r
        active = a
        anchor = an
        if !dirtyRect.isNull { grid.invalidate(dirtyRect) }
        selectionChanged()
    }

    func gridVisibleColumns() -> [Int] { layout.cols }

    func gridColumnHeader(_ c: Int) -> (mark: String, selected: Bool) {
        let q = query
        var mark = ""
        if q.sortColumn == c { mark = q.ascending ? "↑" : "↓" }
        if q.filters[c] != nil { mark += "⏷" }
        return (mark, rects.contains { $0.c0 <= c && c <= $0.c1 })
    }

    func gridRowLabel(_ row: Int) -> (text: String, selected: Bool, pinned: Bool) {
        guard row < visible.count else { return ("", false, false) }
        let sr = visible[row]
        return ("\(sr + 1)", rects.contains { $0.r0 <= row && row <= $0.r1 }, query.pinnedRows.contains(sr))
    }

    func gridHeaderClicked(column c: Int, extend: Bool) {
        guard !visible.isEmpty else { return }
        let start = extend ? anchor.col : c
        let a = GridPoint(row: 0, col: start), b = GridPoint(row: visible.count - 1, col: c)
        gridSelect([GridRect(a, b)], active: GridPoint(row: 0, col: c), anchor: GridPoint(row: 0, col: start))
    }

    func gridHeaderPanel(column c: Int, rect: NSRect, in view: NSView) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        let host = NSHostingController(rootView: ColumnPanel(r: self, column: c, close: { [weak p] in p?.close() }))
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover = p
    }

    func openColumnPanel(_ c: Int) {
        guard let i = layout.position(of: c) else { return }
        grid.scrollTo(row: max(0, min(active.row, visible.count - 1)), col: c)
        let x = layout.xs[i] - grid.scrollOffset.x
        gridHeaderPanel(column: c, rect: NSRect(x: x, y: 0, width: layout.xs[i + 1] - layout.xs[i], height: GridView.headerHeight), in: grid.header)
    }

    // MARK: Selection → formula bar & statistics

    func selectionChanged() {
        address = Sheet.columnName(max(0, active.col)) + (active.row < visible.count ? "\(visible[active.row] + 1)" : "")
        if active.row < visible.count {
            let sr = visible[active.row]
            formulaText = sheet.formulas[Sheet.key(sr, active.col)] ?? sheet.cell(sr, active.col).display
        } else {
            formulaText = ""
        }
        resultText = ""
        var values: [CellValue] = []
        var budget = 2_000_000
        let hiddenCols = query.hiddenColumns
        // A selected merged area counts as the one cell it shows.
        let counted = rects.count == 1 && mergeArea(row: active.row, col: active.col)?.area == rects[0] ? [GridRect(active, active)] : rects
        outer: for rect in counted {
            for r in rect.r0...max(rect.r0, min(rect.r1, visible.count - 1)) where r < visible.count {
                for c in rect.c0...rect.c1 where !hiddenCols.contains(c) {
                    values.append(sheet.cell(visible[r], c))
                    budget -= 1
                    if budget == 0 { break outer }
                }
            }
        }
        stats = SelectionStats(values)
        host?.rendererDidUpdate()
    }

    func fmt(_ d: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(d) >= 1000 ? 2 : 4
        return f.string(from: NSNumber(value: d)) ?? CellValue.format(d)
    }

    func copyStats() {
        var parts = ["计数 \(stats.nonEmpty)"]
        if stats.numeric > 0 {
            parts += ["求和 \(fmt(stats.sum))", "平均 \(fmt(stats.average ?? 0))", "最小 \(fmt(stats.min ?? 0))", "最大 \(fmt(stats.max ?? 0))"]
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "  "), forType: .string)
    }
}
