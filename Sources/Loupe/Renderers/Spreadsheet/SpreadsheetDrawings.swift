import AppKit
import LoupeCore

/// Where the sheet's drawings sit on the grid, and painting them in the grid's paint pass
/// (so they scroll, zoom and freeze exactly like the cells under them).
extension SpreadsheetRenderer {
    /// Screen rectangle of each drawing item, in grid coordinates at the current zoom.
    /// Drawings whose cells are filtered away are left out, as Excel hides them with their rows.
    func drawingFrames() -> [(item: DrawingItem, key: Int, rect: CGRect)] {
        let s = sheet
        guard !s.drawings.isEmpty, layout.rowCount > 0, !layout.cols.isEmpty else { return [] }
        var out: [(DrawingItem, Int, CGRect)] = []
        for (di, d) in s.drawings.enumerated() {
            guard let r = anchorRect(d.anchor) else { continue }
            for (ii, item) in d.items.enumerated() {
                let f = item.frame
                let rect = CGRect(x: r.minX + CGFloat(f.x) * r.width, y: r.minY + CGFloat(f.y) * r.height,
                                  width: CGFloat(f.width) * r.width, height: CGFloat(f.height) * r.height)
                out.append((item, (sheetIndex << 32) | (di << 12) | ii, rect.integral))
            }
        }
        return out
    }

    private func point(_ m: DrawingAnchor.Marker) -> CGPoint? {
        let L = layout
        guard let vr = viewRow(ofSheetRow: m.row) ?? (m.row >= sheet.rows.count ? L.rowCount - 1 : nil), vr < L.rowCount else { return nil }
        // A hidden column: start at the next one shown.
        var c = m.col
        while c < L.colPos.count, L.position(of: c) == nil { c += 1 }
        guard let ci = L.position(of: c) ?? (L.cols.isEmpty ? nil : L.cols.count - 1) else { return nil }
        let x = L.xs[ci] + (c == m.col ? CGFloat(m.colOffset) * zoom : 0)
        return CGPoint(x: min(x, L.xs[ci + 1]), y: L.ys[vr] + min(CGFloat(m.rowOffset) * zoom, L.ys[vr + 1] - L.ys[vr]))
    }

    private func anchorRect(_ a: DrawingAnchor) -> CGRect? {
        if let from = a.from {
            guard let p0 = point(from) else { return nil }
            if let to = a.to, let p1 = point(to), p1.x > p0.x, p1.y > p0.y {
                return CGRect(x: p0.x, y: p0.y, width: p1.x - p0.x, height: p1.y - p0.y)
            }
            return CGRect(x: p0.x, y: p0.y, width: CGFloat(a.width ?? 480) * zoom, height: CGFloat(a.height ?? 288) * zoom)
        }
        return CGRect(x: CGFloat(a.x ?? 0) * zoom, y: CGFloat(a.y ?? 0) * zoom,
                      width: CGFloat(a.width ?? 960) * zoom, height: CGFloat(a.height ?? 600) * zoom)
    }

    func paintDrawings(dirty: NSRect) {
        // Sorting reshuffles rows: a chart anchored to row 4 no longer means anything there.
        guard query.sortColumn == nil else { return }
        let wb = workbook
        for f in drawingFrames() where f.rect.intersects(dirty) {
            drawingPainter.draw(f.item, key: f.key, in: f.rect, scale: zoom) { $0.resolved(using: wb) }
        }
    }
}
