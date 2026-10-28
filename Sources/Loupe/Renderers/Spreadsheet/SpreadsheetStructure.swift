import AppKit
import LoupeCore

/// What undo puts back for an insert/delete or resize: the whole document (a value, so
/// copies are cheap until something changes) plus the view settings that follow its cells.
struct Snapshot {
    var doc: SpreadsheetDocument
    var queries: [SheetQuery]
    var sheetIndex: Int
}

/// Inserting and deleting rows/columns, with undo.
extension SpreadsheetRenderer {
    func snapshot() -> Snapshot { Snapshot(doc: doc, queries: queries, sheetIndex: sheetIndex) }

    func registerUndo(restoring s: Snapshot, name: String) {
        guard let um = grid.window?.undoManager else { return }
        um.registerUndo(withTarget: self) { r in r.restore(s, name: name) }
        um.setActionName(name)
    }

    /// Puts a snapshot back and registers the opposite step (undo ⇄ redo).
    func restore(_ s: Snapshot, name: String) {
        endEditing(commit: false)
        registerUndo(restoring: snapshot(), name: name)
        doc = s.doc
        queries = s.queries
        if sheetIndex != s.sheetIndex { sheetIndex = s.sheetIndex }
        autoWidthsFor = -1
        markDirty()
        reloadSheet()
    }

    // MARK: Insert / delete

    /// Inserts as many rows as are selected, above or below the selection (sheet order).
    func insertRows(below: Bool) {
        guard let g = rects.last, !visible.isEmpty else { return }
        let r0 = max(0, min(g.r0, visible.count - 1)), r1 = max(r0, min(g.r1, visible.count - 1))
        let n = r1 - r0 + 1
        let at = below ? visible[r1] + 1 : visible[r0]
        perform([.insertRows(at: at, count: n)], name: "插入行")
        // Select the new rows.
        if let a = viewRow(ofSheetRow: at), let b = viewRow(ofSheetRow: at + n - 1), let first = layout.cols.first, let last = layout.cols.last {
            gridSelect([GridRect(GridPoint(row: a, col: first), GridPoint(row: b, col: last))], active: GridPoint(row: a, col: active.col), anchor: GridPoint(row: a, col: first))
        }
    }

    func insertColumns(right: Bool) {
        guard let g = rects.last else { return }
        let cols = layout.cols.filter { $0 >= g.c0 && $0 <= g.c1 }
        guard let first = cols.first, let last = cols.last else { return }
        let n = cols.count
        let at = right ? last + 1 : first
        perform([.insertColumns(at: at, count: n)], name: "插入列")
        if !visible.isEmpty {
            gridSelect([GridRect(GridPoint(row: 0, col: at), GridPoint(row: visible.count - 1, col: at + n - 1))],
                       active: GridPoint(row: active.row, col: at), anchor: GridPoint(row: 0, col: at))
        }
    }

    func deleteSelectedRows() {
        var rows = Set<Int>()
        for g in rects { for r in max(0, g.r0)...min(g.r1, visible.count - 1) where r >= 0 { rows.insert(visible[r]) } }
        guard !rows.isEmpty else { return }
        perform(Self.runs(rows).map { .deleteRows(at: $0.lowerBound, count: $0.count) }, name: "删除行")
    }

    func deleteSelectedColumns() {
        var cols = Set<Int>()
        for g in rects { for c in layout.cols where c >= g.c0 && c <= g.c1 { cols.insert(c) } }
        guard !cols.isEmpty else { return }
        perform(Self.runs(cols).map { .deleteColumns(at: $0.lowerBound, count: $0.count) }, name: "删除列")
    }

    /// Consecutive runs, last first, so deleting one never shifts the next.
    static func runs(_ s: Set<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for v in s.sorted() {
            if let last = out.last, last.upperBound == v { out[out.count - 1] = last.lowerBound..<(v + 1) } else { out.append(v..<(v + 1)) }
        }
        return out.reversed()
    }

    // MARK: Merge / unmerge

    /// The selection as a sheet range, when its rows are consecutive in the sheet
    /// (not scattered by sorting or filtering).
    var selectedSheetRange: MergeRange? {
        guard let g = rects.last, g.r0 >= 0, g.r1 < visible.count else { return nil }
        let rows = visible[g.r0...g.r1]
        guard let first = rows.first, let last = rows.last, last - first == rows.count - 1 else { return nil }
        return MergeRange(r0: first, c0: g.c0, r1: last, c1: g.c1)
    }

    var canMergeSelection: Bool {
        guard let m = selectedSheetRange, m.r1 > m.r0 || m.c1 > m.c0 else { return false }
        return !sheet.merges.contains(m)
    }

    var canUnmergeSelection: Bool {
        guard let m = selectedSheetRange else { return false }
        return sheet.merges.contains { $0.overlaps(m) }
    }

    func mergeSelection() {
        guard viewMode == 0 else { return }
        guard let m = selectedSheetRange, m.r1 > m.r0 || m.c1 > m.c0 else {
            host?.showNotice("筛选或排序打乱了行的顺序，无法合并；请先清除筛选和排序", style: .warning, action: nil)
            return
        }
        let lost = doc.cellsClearedByMerging(m, sheet: sheetIndex)
        if lost > 0, let window = grid.window {
            // Like Excel: only the top-left value survives, so ask first.
            let alert = NSAlert()
            alert.messageText = "合并后只保留左上角单元格的内容"
            alert.informativeText = "所选区域里另外 \(lost) 个单元格的内容会被清除（可以用 ⌘Z 撤销）。"
            alert.addButton(withTitle: "合并")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] r in
                if r == .alertFirstButtonReturn { self?.commitMerge(m) }
            }
            return
        }
        commitMerge(m)
    }

    func commitMerge(_ m: MergeRange) {
        endEditing(commit: true)
        let before = snapshot()
        doc.merge(m, sheet: sheetIndex)
        registerUndo(restoring: before, name: "合并单元格")
        markDirty()
        reloadSheet()
        if let vr = viewRow(ofSheetRow: m.r0) { gridSelect([GridRect(GridPoint(row: vr, col: m.c0), GridPoint(row: vr, col: m.c0))], active: GridPoint(row: vr, col: m.c0), anchor: GridPoint(row: vr, col: m.c0)) }
    }

    func unmergeSelection() {
        guard viewMode == 0, let m = selectedSheetRange else { return }
        endEditing(commit: true)
        let before = snapshot()
        guard doc.unmerge(m, sheet: sheetIndex) > 0 else { return }
        registerUndo(restoring: before, name: "取消合并")
        markDirty()
        let keep = rects, a = active, an = anchor
        reloadSheet()
        gridSelect(keep, active: a, anchor: an)
    }

    func perform(_ ops: [StructOp], name: String) {
        guard viewMode == 0, !ops.isEmpty else { return }
        endEditing(commit: true)
        let before = snapshot()
        doc.perform(ops, sheet: sheetIndex)
        for op in ops { query.apply(op) }
        registerUndo(restoring: before, name: name)
        autoWidthsFor = -1
        markDirty()
        reloadSheet()
        let broken = doc.brokenReferenceCount
        if broken > before.doc.brokenReferenceCount {
            host?.showNotice("有 \(broken - before.doc.brokenReferenceCount) 个公式引用了被删除的单元格，显示为 #REF!（⌘Z 可撤销）", style: .warning, action: nil)
        }
    }
}
