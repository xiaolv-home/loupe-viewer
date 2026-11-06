import AppKit
import LoupeCore

/// Column letters with sort/filter marks; drag an edge to resize, click to select, chevron or
/// right-click for the column tools.
final class GridColumnHeader: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    weak var grid: GridView?
    override var isFlipped: Bool { true }
    static let edgeSlop: CGFloat = 4

    private var gridX: CGFloat { grid?.scrollOffset.x ?? 0 }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sheet.setFill()
        dirtyRect.fill()
        guard let grid, let owner = grid.owner else { return }
        let L = owner.gridLayout
        let ox = gridX
        let letterAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: Theme.gutterText]
        let selAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: Theme.emberNS]
        let markAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: Theme.emberNS]
        let chevAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: Theme.gutterText.withAlphaComponent(0.55)]
        for i in L.colIndices(from: dirtyRect.minX + ox, to: dirtyRect.maxX + ox) {
            let c = L.cols[i]
            let x0 = L.xs[i] - ox, x1 = L.xs[i + 1] - ox
            let info = owner.gridColumnHeader(c)
            if info.selected {
                Theme.emberNS.withAlphaComponent(0.10).setFill()
                NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).fill()
                Theme.emberNS.setFill()
                NSRect(x: x0, y: bounds.height - 2, width: x1 - x0, height: 2).fill()
            }
            Theme.hairline.setFill()
            NSRect(x: x1 - 0.5, y: 3, width: 0.5, height: bounds.height - 6).fill()
            let letter = Sheet.columnName(c) as NSString
            let a = info.selected ? selAttrs : letterAttrs
            let size = letter.size(withAttributes: a)
            if x1 - x0 > size.width + 4 {
                letter.draw(at: NSPoint(x: (x0 + x1 - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: a)
            }
            if x1 - x0 > size.width + 34 {
                let m = (info.mark.isEmpty ? "▾" : info.mark) as NSString
                let ma = info.mark.isEmpty ? chevAttrs : markAttrs
                let ms = m.size(withAttributes: ma)
                m.draw(at: NSPoint(x: x1 - ms.width - 7, y: (bounds.height - ms.height) / 2), withAttributes: ma)
            }
        }
        Theme.hairline.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.height - 0.5, width: dirtyRect.width, height: 0.5).fill()
    }

    /// Column index whose right edge is under x (for resizing), if any.
    private func edge(at x: CGFloat, _ L: GridLayout) -> Int? {
        guard !L.cols.isEmpty else { return nil }
        let i = L.colIndex(at: x)
        if abs(L.xs[i + 1] - x) <= Self.edgeSlop { return i }
        if i > 0, abs(L.xs[i] - x) <= Self.edgeSlop { return i - 1 }
        return nil
    }

    override func resetCursorRects() {
        guard let grid else { return }
        let L = grid.layoutInfo
        let ox = gridX
        for i in L.colIndices(from: ox, to: ox + bounds.width) {
            addCursorRect(NSRect(x: L.xs[i + 1] - ox - Self.edgeSlop, y: 0, width: Self.edgeSlop * 2, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with e: NSEvent) {
        guard let grid, let owner = grid.owner else { return }
        let L = grid.layoutInfo
        guard !L.cols.isEmpty else { return }
        let x = convert(e.locationInWindow, from: nil).x + gridX
        if let i = edge(at: x, L) {
            if e.clickCount == 2 { owner.gridAutoFitColumn(L.cols[i]); return }
            grid.trackResize(from: e, column: L.cols[i], row: nil, start: L.xs[i + 1] - L.xs[i])
            return
        }
        let i = L.colIndex(at: x)
        guard x < L.width else { return }
        let x1 = L.xs[i + 1]
        if x > x1 - 20 && x1 - L.xs[i] > 44 {
            owner.gridHeaderPanel(column: L.cols[i], rect: NSRect(x: L.xs[i] - gridX, y: 0, width: x1 - L.xs[i], height: bounds.height), in: self)
            return
        }
        grid.selectColumns(from: e, col: L.cols[i])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let grid, let owner = grid.owner else { return nil }
        let L = grid.layoutInfo
        let x = convert(event.locationInWindow, from: nil).x + gridX
        guard !L.cols.isEmpty, x < L.width else { return nil }
        let c = L.cols[L.colIndex(at: x)]
        let (rects, _, _) = owner.gridSelection()
        let whole = rects.contains { $0.c0 <= c && c <= $0.c1 && $0.r0 == 0 && $0.r1 >= L.rowCount - 1 }
        if !whole { owner.gridHeaderClicked(column: c, extend: false) }
        return owner.gridColumnMenu(column: c)
    }
}

/// Row numbers for the frozen band or the scrolling body; drag a bottom edge to resize.
final class GridRowGutter: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    let isFrozenBand: Bool
    weak var grid: GridView?
    static let edgeSlop: CGFloat = 3

    init(frozen: Bool) {
        isFrozenBand = frozen
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var gridY: CGFloat {
        guard let grid else { return 0 }
        return isFrozenBand ? 0 : grid.scrollOffset.y + grid.layoutInfo.frozenHeight
    }

    private var band: Range<Int> {
        let L = grid?.layoutInfo ?? GridLayout()
        return isFrozenBand ? 0..<min(L.frozenRows, L.rowCount) : min(L.frozenRows, L.rowCount)..<L.rowCount
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sheet.setFill()
        dirtyRect.fill()
        guard let grid, let owner = grid.owner else { return }
        let L = owner.gridLayout
        let oy = gridY
        let rows = L.rows(from: dirtyRect.minY + oy, to: dirtyRect.maxY + oy).clamped(to: band)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        for r in rows {
            let y0 = L.ys[r] - oy, y1 = L.ys[r + 1] - oy
            let info = owner.gridRowLabel(r)
            if info.selected {
                Theme.emberNS.withAlphaComponent(0.10).setFill()
                NSRect(x: 0, y: y0, width: bounds.width, height: y1 - y0).fill()
                Theme.emberNS.setFill()
                NSRect(x: bounds.width - 2, y: y0, width: 2, height: y1 - y0).fill()
            } else if info.pinned {
                Theme.hairline.setFill()
                NSRect(x: 0, y: y0, width: bounds.width, height: y1 - y0).fill()
            }
            Theme.hairline.setFill()
            NSRect(x: 3, y: y1 - 0.5, width: bounds.width - 6, height: 0.5).fill()
            guard y1 - y0 >= 9 else { continue }
            let attrs: [NSAttributedString.Key: Any] = [.font: info.selected ? bold : font,
                                                        .foregroundColor: info.selected ? Theme.emberNS : Theme.gutterText]
            let s = info.text as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: bounds.width - size.width - 8, y: (y0 + y1 - size.height) / 2), withAttributes: attrs)
        }
        Theme.hairline.setFill()
        NSRect(x: bounds.width - 0.5, y: dirtyRect.minY, width: 0.5, height: dirtyRect.height).fill()
    }

    private func edge(at y: CGFloat, _ L: GridLayout) -> Int? {
        guard L.rowCount > 0 else { return nil }
        let r = L.row(at: y)
        if abs(L.ys[r + 1] - y) <= Self.edgeSlop && band.contains(r) { return r }
        if r > 0, abs(L.ys[r] - y) <= Self.edgeSlop, band.contains(r - 1) { return r - 1 }
        return nil
    }

    override func resetCursorRects() {
        guard let grid else { return }
        let L = grid.layoutInfo
        let oy = gridY
        for r in L.rows(from: oy, to: oy + bounds.height).clamped(to: band) {
            addCursorRect(NSRect(x: 0, y: L.ys[r + 1] - oy - Self.edgeSlop, width: bounds.width, height: Self.edgeSlop * 2), cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with e: NSEvent) {
        guard let grid else { return }
        let L = grid.layoutInfo
        guard L.rowCount > 0 else { return }
        let y = convert(e.locationInWindow, from: nil).y + gridY
        if let r = edge(at: y, L) {
            grid.trackResize(from: e, column: nil, row: r, start: L.ys[r + 1] - L.ys[r])
            return
        }
        guard y < L.height else { return }
        grid.selectRows(from: e, row: L.row(at: y))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let grid, let owner = grid.owner else { return nil }
        let L = grid.layoutInfo
        let y = convert(event.locationInWindow, from: nil).y + gridY
        guard L.rowCount > 0, y < L.height else { return nil }
        let r = L.row(at: y)
        let (rects, _, _) = owner.gridSelection()
        let whole = rects.contains { $0.r0 <= r && r <= $0.r1 && $0.c0 <= (L.cols.first ?? 0) && $0.c1 >= (L.cols.last ?? 0) }
        if !whole, let first = L.cols.first, let last = L.cols.last {
            owner.gridSelect([GridRect(GridPoint(row: r, col: first), GridPoint(row: r, col: last))],
                             active: GridPoint(row: r, col: first), anchor: GridPoint(row: r, col: first))
        }
        return owner.gridRowMenu(row: r)
    }

    override func scrollWheel(with e: NSEvent) { grid?.scroll.scrollWheel(with: e) }
}

/// Top-left corner: selects everything.
final class GridCorner: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    weak var grid: GridView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.sheet.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
        NSRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: bounds.width - 5, y: bounds.height - 11))
        p.line(to: NSPoint(x: bounds.width - 5, y: bounds.height - 5))
        p.line(to: NSPoint(x: bounds.width - 11, y: bounds.height - 5))
        p.close()
        Theme.gutterText.withAlphaComponent(0.5).setFill()
        p.fill()
    }
    override func mouseDown(with e: NSEvent) {
        grid?.window?.makeFirstResponder(grid)
        grid?.selectAll(nil)
    }
}
