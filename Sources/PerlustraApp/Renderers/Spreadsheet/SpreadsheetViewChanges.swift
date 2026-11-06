import AppKit
import PerlustraCore

/// Sorting, filtering and hiding. These only change what is shown, never the file, and each can be
/// undone. Rows move whole: the view is a list of sheet rows, so a row's cells cannot part company.
extension SpreadsheetRenderer {
    private func changeView(_ name: String, resetSelection: Bool = false, _ change: (inout SheetQuery) -> Void) {
        var changed = query
        change(&changed)
        guard changed != query else { return }
        rememberView(query, sheet: sheetIndex, name: name)
        query = changed
        reloadSheet(resetSelection: resetSelection)
    }

    private func rememberView(_ saved: SheetQuery, sheet: Int, name: String) {
        history.registerUndo(withTarget: self) { r in r.restoreView(saved, sheet: sheet, name: name) }
        history.setActionName(name)
    }

    /// Puts an earlier view back and registers the opposite step (undo ⇄ redo).
    private func restoreView(_ saved: SheetQuery, sheet: Int, name: String) {
        guard queries.indices.contains(sheet) else { return }
        let undoing = history.isUndoing
        rememberView(queries[sheet], sheet: sheet, name: name)
        queries[sheet] = saved
        let otherSheet = sheetIndex != sheet
        if otherSheet { sheetIndex = sheet }
        reloadSheet(resetSelection: otherSheet)
        flash("\(undoing ? "已撤销" : "已恢复")：\(name)")
    }

    func setHeaderRow(_ on: Bool) {
        let row = on ? SheetQuery.guessedHeaderRow(in: sheet) ?? 0 : nil
        changeView(on ? "自动识别表头" : "取消表头", resetSelection: true) { $0.headerRowIndex = row }
    }

    func sort(column c: Int, ascending: Bool?) {
        changeView(ascending == nil ? "取消排序" : "排序") { q in
            if let ascending {
                q.sortColumn = c
                q.ascending = ascending
            } else {
                q.sortColumn = nil
            }
        }
    }

    func setFilter(_ rule: FilterRule?, column c: Int) {
        changeView(rule == nil ? "取消筛选" : "筛选", resetSelection: true) { $0.filters[c] = rule }
    }

    func clearFilters() {
        changeView("清除筛选和排序", resetSelection: true) { q in
            q.filters = [:]
            q.sortColumn = nil
        }
    }

    func hideSelectedRows() {
        let rows = rects.flatMap { rect in (rect.r0...rect.r1).filter { $0 < visible.count }.map { visible[$0] } }
        changeView("隐藏行", resetSelection: true) { $0.hiddenRows.formUnion(rows) }
    }

    func hideColumns(_ cols: [Int]) {
        changeView("隐藏列") { $0.hiddenColumns.formUnion(cols) }
    }

    func unhideAll() {
        changeView("显示隐藏的行和列") { q in
            q.hiddenRows = []
            q.hiddenColumns = []
        }
    }

    // MARK: Starting at a chosen row

    /// Sorting and filtering take in this sheet row and those below it; the rows above stay where they are.
    func startData(atSheetRow row: Int) {
        guard row < sheet.rows.count else { return }
        changeView("从第 \(row + 1) 行开始", resetSelection: true) { $0.startData(at: row) }
        flash("排序和筛选从第 \(row + 1) 行开始，上面的行不动")
    }

    /// Sorts this sheet row and those below it by a column, keeping the rows above in place.
    func sort(fromSheetRow row: Int, column c: Int, ascending: Bool) {
        changeView("从第 \(row + 1) 行开始排序") { q in
            q.startData(at: row)
            q.sortColumn = c
            q.ascending = ascending
        }
        selectFirstDataCell(column: c)
        flash("第 \(row + 1) 行往下已排序，每行整行移动，上面的行不动")
    }

    /// Opens a column's filter for this sheet row and those below it.
    func openFilter(fromSheetRow row: Int, column c: Int) {
        changeView("从第 \(row + 1) 行开始筛选") { $0.startData(at: row) }
        openColumnPanel(c)
    }

    private func selectFirstDataCell(column c: Int) {
        let pinned = query.pinnedRows.filter { viewRow(ofSheetRow: $0) != nil }.count
        guard pinned < visible.count else { return }
        let cell = GridPoint(row: pinned, col: c)
        gridSelect([GridRect(cell, cell)], active: cell, anchor: cell)
    }
}
