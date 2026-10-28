import AppKit
import LoupeCore

/// Column widths, row heights and zoom.
extension SpreadsheetRenderer {
    // MARK: Resizing and zoom

    func gridResizeColumn(_ c: Int, width: CGFloat, done: Bool) {
        if resizeSnapshot == nil { resizeSnapshot = snapshot() }
        doc.setColumnWidth(SheetMetrics.chars(px: width / zoom), sheet: sheetIndex, column: c, persist: editingEnabled)
        if done {
            rebuildFitHeights()
            finishResize(name: "调整列宽")
        }
        relayout()
    }

    func gridResizeRow(_ row: Int, height: CGFloat, done: Bool) {
        guard row < visible.count else { return }
        if resizeSnapshot == nil { resizeSnapshot = snapshot() }
        let sr = visible[row]
        doc.setRowHeight(Double(height / zoom / SheetMetrics.ptToPx), sheet: sheetIndex, row: sr, persist: editingEnabled)
        if done {
            finishResize(name: "调整行高")
        }
        relayout()
    }

    /// Double-click on a column edge: fit the widest text in the column.
    func gridAutoFitColumn(_ c: Int) {
        let before = snapshot()
        var w: CGFloat = 40
        for sr in visible.prefix(5000) where !mergeCovered.contains(Sheet.key(sr, c)) && mergeTopLeft[Sheet.key(sr, c)] == nil {
            let formatted = workbook.formatted(sheetIndex, sr, c)
            if formatted.text.isEmpty { continue }
            let lk = look(sr, c, value: sheet.cell(sr, c), colorOverride: formatted.color)
            if lk.wraps { continue }
            w = max(w, (formatted.text as NSString).size(withAttributes: [.font: lk.font]).width / zoom + SheetMetrics.padX * 2 + 4)
        }
        doc.setColumnWidth(SheetMetrics.chars(px: min(900, ceil(w))), sheet: sheetIndex, column: c, persist: editingEnabled)
        resizeSnapshot = before
        finishResize(name: "调整列宽")
        rebuildFitHeights()
        relayout()
    }

    private func finishResize(name: String) {
        guard let before = resizeSnapshot else { return }
        resizeSnapshot = nil
        // Only a saved change when editing is on; otherwise (and in text files) it is a view setting.
        guard workbook.csv == nil, editingEnabled else { return }
        registerUndo(restoring: before, name: name)
        markDirty()
    }

    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func setZoom(_ z: CGFloat) {
        let nz = max(0.4, min(3, z))
        guard abs(nz - zoom) > 0.001 else { return }
        endEditing(commit: true)
        // Keep the cell at the top-left corner in place.
        let L = layout
        let o = grid.scrollOffset
        let topRow = L.rowCount > 0 ? L.row(at: o.y + L.frozenHeight) : 0
        let leftCol = L.cols.isEmpty ? 0 : L.colIndex(at: o.x)
        let fy = L.rowCount > 0 ? (o.y + L.frozenHeight - L.ys[topRow]) / max(1, L.ys[topRow + 1] - L.ys[topRow]) : 0
        let fx = L.cols.isEmpty ? 0 : (o.x - L.xs[leftCol]) / max(1, L.xs[leftCol + 1] - L.xs[leftCol])
        zoom = nz
        lookCache = [:]
        relayout()
        let N = layout
        if N.rowCount > topRow, N.cols.count > leftCol {
            let y = N.ys[topRow] + fy * (N.ys[topRow + 1] - N.ys[topRow])
            let x = N.xs[leftCol] + fx * (N.xs[leftCol + 1] - N.xs[leftCol])
            grid.scrollOrigin(to: NSPoint(x: x, y: y))
        }
        host?.rendererDidUpdate()
    }

    /// ⌘+ / ⌘−: the table, or the original preview when that is showing.
    func stepZoom(_ d: Int) {
        let steps = Self.zoomSteps
        let current = viewMode == 1 ? originalZoom : zoom
        let next = d > 0 ? (steps.first { $0 > current + 0.001 } ?? steps.last!) : (steps.last { $0 < current - 0.001 } ?? steps.first!)
        if viewMode == 1 { originalZoom = next; host?.rendererDidUpdate() } else { setZoom(next) }
    }

    func gridMagnify(_ factor: CGFloat, done: Bool) {
        var z = zoom * factor
        if done, abs(z - 1) < 0.04 { z = 1 }      // settle on 100% when close
        setZoom(z)
    }

    func gridAppearanceChanged() { lookCache = [:] }
}
