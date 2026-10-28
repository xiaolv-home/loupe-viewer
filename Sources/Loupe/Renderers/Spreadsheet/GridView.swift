import AppKit
import LoupeCore

/// A rectangle of cells in *view* coordinates: rows index the visible-row list, columns are sheet columns.
struct GridRect: Equatable {
    var r0: Int, r1: Int, c0: Int, c1: Int
    init(_ a: GridPoint, _ b: GridPoint) {
        r0 = min(a.row, b.row); r1 = max(a.row, b.row)
        c0 = min(a.col, b.col); c1 = max(a.col, b.col)
    }
    func contains(_ r: Int, _ c: Int) -> Bool { r >= r0 && r <= r1 && c >= c0 && c <= c1 }
    var cellCount: Int { (r1 - r0 + 1) * (c1 - c0 + 1) }
}

struct GridPoint: Equatable, Hashable {
    var row: Int
    var col: Int
}

/// Geometry of the grid in zoomed points. Rows are view rows (after filtering and sorting);
/// `cols` are the sheet columns on screen, in order. The first `frozenRows` rows stay on top.
struct GridLayout {
    var cols: [Int] = []
    var colPos: [Int] = []          // sheet column → index in `cols`, -1 when hidden
    var xs: [CGFloat] = [0]         // left edge of each shown column, plus the total width
    var ys: [CGFloat] = [0]         // top edge of each view row, plus the total height
    var frozenRows = 0

    var rowCount: Int { ys.count - 1 }
    var width: CGFloat { xs[xs.count - 1] }
    var height: CGFloat { ys[ys.count - 1] }
    var frozenHeight: CGFloat { ys[min(frozenRows, rowCount)] }

    private static func index(in edges: [CGFloat], at v: CGFloat) -> Int {
        // Largest i with edges[i] <= v, clamped to a real cell.
        var lo = 0, hi = edges.count - 2
        guard hi >= 0 else { return 0 }
        if v <= edges[0] { return 0 }
        if v >= edges[hi] { return hi }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if edges[mid] <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func row(at y: CGFloat) -> Int { Self.index(in: ys, at: y) }
    func colIndex(at x: CGFloat) -> Int { Self.index(in: xs, at: x) }
    func position(of col: Int) -> Int? { col >= 0 && col < colPos.count && colPos[col] >= 0 ? colPos[col] : nil }

    func rows(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        guard rowCount > 0, maxY > 0, minY < height else { return 0..<0 }
        return row(at: minY)..<(row(at: maxY - 0.01) + 1)
    }

    func colIndices(from minX: CGFloat, to maxX: CGFloat) -> Range<Int> {
        guard !cols.isEmpty, maxX > 0, minX < width else { return 0..<0 }
        return colIndex(at: minX)..<(colIndex(at: maxX - 0.01) + 1)
    }

    func rect(row: Int, col: Int) -> NSRect? {
        guard row >= 0, row < rowCount, let i = position(of: col) else { return nil }
        return NSRect(x: xs[i], y: ys[row], width: xs[i + 1] - xs[i], height: ys[row + 1] - ys[row])
    }

    /// Screen rectangle covered by a selection (hidden columns at its edges are skipped).
    func rect(_ g: GridRect) -> NSRect? {
        guard rowCount > 0 else { return nil }
        let r0 = max(0, g.r0), r1 = min(rowCount - 1, g.r1)
        guard r0 <= r1 else { return nil }
        var p0: Int?, p1: Int?
        for c in g.c0...min(g.c1, max(g.c0, colPos.count - 1)) {
            if let p = position(of: c) { if p0 == nil { p0 = p }; p1 = p }
        }
        guard let a = p0, let b = p1 else { return nil }
        return NSRect(x: xs[a], y: ys[r0], width: xs[b + 1] - xs[a], height: ys[r1 + 1] - ys[r0])
    }
}

/// What the grid asks of its owner (the spreadsheet renderer).
@MainActor
protocol GridViewOwner: AnyObject {
    var gridLayout: GridLayout { get }
    /// Paints rows × column positions into the current context, in grid coordinates.
    func gridPaint(rows: Range<Int>, colIndices: Range<Int>, dirty: NSRect)
    func gridSelect(_ rects: [GridRect], active: GridPoint, anchor: GridPoint)
    func gridSelection() -> (rects: [GridRect], active: GridPoint, anchor: GridPoint)
    func gridMenu(at point: GridPoint?) -> NSMenu?
    func gridColumnMenu(column: Int) -> NSMenu?
    func gridRowMenu(row: Int) -> NSMenu?
    func gridHeaderClicked(column: Int, extend: Bool)
    func gridHeaderPanel(column: Int, rect: NSRect, in view: NSView)
    func gridColumnHeader(_ col: Int) -> (mark: String, selected: Bool)
    func gridRowLabel(_ row: Int) -> (text: String, selected: Bool, pinned: Bool)
    var gridGutterDigits: Int { get }
    func gridResizeColumn(_ col: Int, width: CGFloat, done: Bool)
    func gridResizeRow(_ row: Int, height: CGFloat, done: Bool)
    func gridAutoFitColumn(_ col: Int)
    func gridCopy()
    func gridBeginEdit(_ p: GridPoint, typed: String?)
    func gridClearSelection()
    func gridPaste(_ text: String)
    func gridMagnify(_ factor: CGFloat, done: Bool)
    /// The merged area containing a cell, if any (keyboard moves step over it).
    func gridMergeArea(row: Int, col: Int) -> GridRect?
    /// False when the table is only for looking: keys then navigate instead of editing.
    var gridEditable: Bool { get }
    func gridAppearanceChanged()
}

/// The spreadsheet grid: a column header and row gutter that follow scrolling, a frozen band
/// for header rows, and the scrolling body. All cells are drawn by the owner (no cell views),
/// so merged areas, text overflowing into empty neighbours and zoom behave like a spreadsheet.
final class GridView: NSView {
    weak var owner: GridViewOwner?
    let scroll = NSScrollView()
    let body = GridPane(frozen: false)
    let frozen = GridPane(frozen: true)
    let header = GridColumnHeader()
    let gutter = GridRowGutter(frozen: false)
    let frozenGutter = GridRowGutter(frozen: true)
    let corner = GridCorner()
    static let headerHeight: CGFloat = 22
    private(set) var gutterWidth: CGFloat = 40

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var layoutInfo: GridLayout { owner?.gridLayout ?? GridLayout() }
    var scrollOffset: NSPoint { scroll.contentView.bounds.origin }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.sheet
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // macOS 14+ no longer clips drawing to a view's bounds by default; these views paint
        // whole dirty rects, so they must clip or they cover their neighbours.
        clipsToBounds = true
        for v in [scroll, frozen, frozenGutter, gutter, header, corner] as [NSView] { v.clipsToBounds = true; addSubview(v) }
        body.clipsToBounds = true
        for p in [body, frozen] { p.grid = self }
        for g in [gutter, frozenGutter] { g.grid = self }
        header.grid = self
        corner.grid = self
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Call after the owner's layout changed (rows, columns, sizes, zoom).
    func reload() {
        let L = layoutInfo
        let digits = max(2, owner?.gridGutterDigits ?? 2)
        gutterWidth = CGFloat(digits) * 7 + 18
        body.setFrameSize(NSSize(width: max(L.width, 1), height: max(L.height - L.frozenHeight, 1)))
        layoutGrid()
        redrawAll()
        window?.invalidateCursorRects(for: header)
        window?.invalidateCursorRects(for: gutter)
        window?.invalidateCursorRects(for: frozenGutter)
    }

    override func layout() {
        super.layout()
        layoutGrid()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutGrid()
    }

    private func layoutGrid() {
        let L = layoutInfo
        let h = Self.headerHeight, gw = gutterWidth, fh = L.frozenRows > 0 ? L.frozenHeight : 0
        let w = bounds.width, H = bounds.height
        corner.frame = NSRect(x: 0, y: 0, width: gw, height: h)
        header.frame = NSRect(x: gw, y: 0, width: max(0, w - gw), height: h)
        frozenGutter.frame = NSRect(x: 0, y: h, width: gw, height: fh)
        frozen.frame = NSRect(x: gw, y: h, width: max(0, w - gw), height: fh)
        frozen.isHidden = fh == 0
        frozenGutter.isHidden = fh == 0
        gutter.frame = NSRect(x: 0, y: h + fh, width: gw, height: max(0, H - h - fh))
        scroll.frame = NSRect(x: gw, y: h + fh, width: max(0, w - gw), height: max(0, H - h - fh))
    }

    func redrawAll() {
        for v in [body, frozen, header, gutter, frozenGutter, corner] as [NSView] { v.needsDisplay = true }
    }

    /// Redraws the cells under a grid-coordinate rectangle, plus headers and gutters.
    func invalidate(_ r: NSRect) {
        let L = layoutInfo
        let rr = r.insetBy(dx: -3, dy: -3)
        body.setNeedsDisplay(rr.offsetBy(dx: 0, dy: -L.frozenHeight))
        if L.frozenRows > 0 { frozen.setNeedsDisplay(rr.offsetBy(dx: -scrollOffset.x, dy: 0)) }
        header.needsDisplay = true
        gutter.needsDisplay = true
        frozenGutter.needsDisplay = true
    }

    @objc private func scrolled() {
        header.needsDisplay = true
        gutter.needsDisplay = true
        if layoutInfo.frozenRows > 0 { frozen.needsDisplay = true }
        window?.invalidateCursorRects(for: header)
        window?.invalidateCursorRects(for: gutter)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.gridAppearanceChanged()
        scroll.backgroundColor = Theme.sheet
        redrawAll()
    }

    // MARK: Coordinates

    /// Grid coordinates of a window location (unclamped; the frozen band maps to the top rows).
    func gridLocation(_ windowPoint: NSPoint) -> NSPoint {
        let p = convert(windowPoint, from: nil)
        let L = layoutInfo
        let x = p.x - gutterWidth + scrollOffset.x
        let top = Self.headerHeight
        if L.frozenRows > 0 && p.y < top + L.frozenHeight { return NSPoint(x: x, y: p.y - top) }
        return NSPoint(x: x, y: p.y - top + scrollOffset.y)
    }

    func cell(at g: NSPoint) -> GridPoint? {
        let L = layoutInfo
        guard L.rowCount > 0, !L.cols.isEmpty else { return nil }
        return GridPoint(row: L.row(at: g.y), col: L.cols[L.colIndex(at: g.x)])
    }

    /// The view and local rectangle where an in-place editor for a cell goes.
    func editorHost(row: Int, col: Int) -> (NSView, NSRect)? {
        let L = layoutInfo
        guard let r = L.rect(row: row, col: col) else { return nil }
        if row < L.frozenRows { return (frozen, r.offsetBy(dx: -scrollOffset.x, dy: 0)) }
        return (body, r.offsetBy(dx: 0, dy: -L.frozenHeight))
    }

    func scrollTo(row: Int, col: Int) {
        let L = layoutInfo
        guard row >= 0, row < L.rowCount else { return }
        let x: NSRect
        if let p = L.position(of: col) { x = NSRect(x: L.xs[p], y: 0, width: L.xs[p + 1] - L.xs[p], height: 0) } else { x = .zero }
        var target: NSRect
        if row < L.frozenRows {
            target = NSRect(x: x.minX, y: body.visibleRect.minY, width: x.width, height: 1)
        } else {
            target = NSRect(x: x.minX, y: L.ys[row] - L.frozenHeight, width: x.width, height: L.ys[row + 1] - L.ys[row])
        }
        if x.width == 0 { target.origin.x = body.visibleRect.minX; target.size.width = 1 }
        body.scrollToVisible(target)
    }

    /// Scrolls so that the given grid point is at the top-left of the scrolling area.
    func scrollOrigin(to p: NSPoint) {
        let L = layoutInfo
        let maxX = max(0, body.frame.width - scroll.contentView.bounds.width)
        let maxY = max(0, body.frame.height - scroll.contentView.bounds.height)
        let target = NSPoint(x: min(maxX, max(0, p.x)), y: min(maxY, max(0, p.y - L.frozenHeight)))
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    var visibleRowCount: Int {
        let L = layoutInfo
        let vr = body.visibleRect
        return max(1, L.rows(from: vr.minY + L.frozenHeight, to: vr.maxY + L.frozenHeight).count - 1)
    }

    // MARK: Mouse

    enum TrackMode { case cells, rows, cols }

    func paneMouseDown(_ e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let owner, let p = cell(at: gridLocation(e.locationInWindow)) else { return }
        if e.clickCount == 2 {
            owner.gridBeginEdit(p, typed: nil)
            return
        }
        var (rects, _, anchor) = owner.gridSelection()
        if e.modifierFlags.contains(.shift) {
            owner.gridSelect([GridRect(anchor, p)], active: p, anchor: anchor)
        } else if e.modifierFlags.contains(.command) {
            rects.append(GridRect(p, p))
            owner.gridSelect(rects, active: p, anchor: p)
        } else {
            owner.gridSelect([GridRect(p, p)], active: p, anchor: p)
        }
        track(.cells, from: e)
    }

    func selectRows(from e: NSEvent, row: Int) {
        guard let owner else { return }
        window?.makeFirstResponder(self)
        let L = layoutInfo
        guard let first = L.cols.first, let last = L.cols.last else { return }
        var (rects, _, anchor) = owner.gridSelection()
        let a = GridPoint(row: row, col: first), b = GridPoint(row: row, col: last)
        if e.modifierFlags.contains(.shift) {
            rects = [GridRect(GridPoint(row: anchor.row, col: first), b)]
        } else if e.modifierFlags.contains(.command) {
            rects.append(GridRect(a, b)); anchor = a
        } else { rects = [GridRect(a, b)]; anchor = a }
        owner.gridSelect(rects, active: a, anchor: anchor)
        track(.rows, from: e)
    }

    func selectColumns(from e: NSEvent, col: Int) {
        guard let owner else { return }
        window?.makeFirstResponder(self)
        owner.gridHeaderClicked(column: col, extend: e.modifierFlags.contains(.shift))
        track(.cols, from: e)
    }

    /// Classic tracking loop: keeps extending the selection and auto-scrolling even while the
    /// pointer rests outside the grid (periodic events), until the button is released.
    private func track(_ mode: TrackMode, from start: NSEvent) {
        guard let window else { return }
        var loc = start.locationInWindow
        NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if ev.type == .leftMouseUp { break }
            if ev.type == .leftMouseDragged { loc = ev.locationInWindow }
            let inScroll = scroll.convert(loc, from: nil)
            if !scroll.bounds.contains(inScroll),
               let fake = NSEvent.mouseEvent(with: .leftMouseDragged, location: loc, modifierFlags: [], timestamp: ev.timestamp,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                body.autoscroll(with: fake)
            }
            guard let owner, let p = cell(at: gridLocation(loc)) else { continue }
            var (rects, _, anchor) = owner.gridSelection()
            let L = layoutInfo
            let rect: GridRect
            let active: GridPoint
            switch mode {
            case .cells:
                rect = GridRect(anchor, p); active = p
            case .rows:
                rect = GridRect(GridPoint(row: anchor.row, col: L.cols.first ?? 0), GridPoint(row: p.row, col: L.cols.last ?? 0))
                active = GridPoint(row: p.row, col: L.cols.first ?? 0)
            case .cols:
                rect = GridRect(GridPoint(row: 0, col: anchor.col), GridPoint(row: max(0, L.rowCount - 1), col: p.col))
                active = GridPoint(row: 0, col: p.col)
            }
            if rects.isEmpty { rects = [rect] } else if rects[rects.count - 1] == rect { continue } else { rects[rects.count - 1] = rect }
            owner.gridSelect(rects, active: active, anchor: anchor)
        }
    }

    /// Drags a column's right edge (`horizontal`) or a row's bottom edge until release.
    func trackResize(from e: NSEvent, column: Int?, row: Int?, start size: CGFloat) {
        guard let window, let owner else { return }
        let origin = e.locationInWindow
        var current = size
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let d = column != nil ? ev.locationInWindow.x - origin.x : origin.y - ev.locationInWindow.y
            current = max(column != nil ? 12 : 8, size + d)
            if let c = column { owner.gridResizeColumn(c, width: current, done: ev.type == .leftMouseUp) }
            if let r = row { owner.gridResizeRow(r, height: current, done: ev.type == .leftMouseUp) }
            if ev.type == .leftMouseUp { break }
        }
    }

    func cellMenu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let p = cell(at: gridLocation(event.locationInWindow))
        if let p {
            // Right-click outside the selection moves it, like Numbers/Excel.
            let (rects, _, _) = owner.gridSelection()
            if !rects.contains(where: { $0.contains(p.row, p.col) }) { owner.gridSelect([GridRect(p, p)], active: p, anchor: p) }
        }
        return owner.gridMenu(at: p)
    }

    override func magnify(with e: NSEvent) {
        owner?.gridMagnify(1 + e.magnification, done: e.phase == .ended || e.phase == .cancelled)
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        guard let owner else { super.keyDown(with: e); return }
        let L = layoutInfo
        guard L.rowCount > 0, !L.cols.isEmpty else { super.keyDown(with: e); return }
        var (rects, active, anchor) = owner.gridSelection()
        let shift = e.modifierFlags.contains(.shift)
        let cmd = e.modifierFlags.contains(.command)
        var dr = 0, dc = 0
        switch e.keyCode {
        case 123: dc = -1
        case 124: dc = 1
        case 36, 76, 120:   // Return / Enter / F2 start editing the active cell (or move down)
            if owner.gridEditable { owner.gridBeginEdit(active, typed: nil); return }
            dr = shift ? -1 : 1
        case 51, 117:       // Delete / Forward delete clear the selection
            if owner.gridEditable { owner.gridClearSelection() }
            return
        case 125: dr = 1
        case 126: dr = -1
        case 48: dc = shift ? -1 : 1
        case 116: dr = -visibleRowCount
        case 121: dr = visibleRowCount
        default:
            // Typing a character starts editing with that character, like a spreadsheet.
            if owner.gridEditable, !cmd, !e.modifierFlags.contains(.control), let ch = e.characters, let u = ch.unicodeScalars.first,
               u.value >= 0x20, u.value != 0x7F, !(0xF700...0xF8FF).contains(u.value) {
                owner.gridBeginEdit(active, typed: ch)
                return
            }
            if cmd, e.charactersIgnoringModifiers == "a" { selectAll(nil); return }
            super.keyDown(with: e)
            return
        }
        // Step out of a merged area from its far edge.
        var from = active.row, pos = L.position(of: active.col) ?? 0
        if !shift, let m = owner.gridMergeArea(row: active.row, col: active.col) {
            if dr > 0 { from = m.r1 }
            if dc > 0 { pos = L.position(of: m.c1) ?? pos }
        }
        var row = from + dr, p = pos + dc
        if cmd {
            // Jump to the edge like Excel's ⌘-arrow.
            if dr < 0 { row = 0 } else if dr > 0 { row = L.rowCount - 1 }
            if dc < 0 { p = 0 } else if dc > 0 { p = L.cols.count - 1 }
        }
        row = max(0, min(L.rowCount - 1, row))
        p = max(0, min(L.cols.count - 1, p))
        let next = GridPoint(row: row, col: L.cols[p])
        // Shift extends with arrows; Shift-Tab and Shift-Return just move back.
        if shift && ![48, 36, 76, 120].contains(e.keyCode) {
            rects = [GridRect(anchor, next)]
            owner.gridSelect(rects, active: next, anchor: anchor)
        } else {
            owner.gridSelect([GridRect(next, next)], active: next, anchor: next)
        }
        scrollTo(row: next.row, col: next.col)
    }

    @objc override func selectAll(_ sender: Any?) {
        let L = layoutInfo
        guard let owner, L.rowCount > 0, let first = L.cols.first, let last = L.cols.last else { return }
        let (_, active, _) = owner.gridSelection()
        owner.gridSelect([GridRect(GridPoint(row: 0, col: first), GridPoint(row: L.rowCount - 1, col: last))],
                         active: active, anchor: GridPoint(row: 0, col: first))
    }

    @objc func copy(_ sender: Any?) { owner?.gridCopy() }
    @objc func paste(_ sender: Any?) {
        if let t = NSPasteboard.general.string(forType: .string) { owner?.gridPaste(t) }
    }
    @objc func delete(_ sender: Any?) { owner?.gridClearSelection() }
}

/// The scrolling body (documentView) or the frozen band of header rows. It only draws;
/// input goes to the GridView.
final class GridPane: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    let isFrozenBand: Bool
    weak var grid: GridView?

    init(frozen: Bool) {
        isFrozenBand = frozen
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Grid coordinates of this view's local origin.
    var gridOrigin: NSPoint {
        guard let grid else { return .zero }
        return isFrozenBand ? NSPoint(x: grid.scrollOffset.x, y: 0) : NSPoint(x: 0, y: grid.layoutInfo.frozenHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid, let owner = grid.owner, let ctx = NSGraphicsContext.current?.cgContext else {
            Theme.sheet.setFill(); dirtyRect.fill(); return
        }
        let L = owner.gridLayout
        let o = gridOrigin
        let g = dirtyRect.offsetBy(dx: o.x, dy: o.y)
        var rows = L.rows(from: g.minY, to: g.maxY)
        let band = isFrozenBand ? 0..<min(L.frozenRows, L.rowCount) : min(L.frozenRows, L.rowCount)..<L.rowCount
        rows = rows.clamped(to: band)
        ctx.saveGState()
        ctx.translateBy(x: -o.x, y: -o.y)
        owner.gridPaint(rows: rows, colIndices: L.colIndices(from: g.minX, to: g.maxX), dirty: g)
        ctx.restoreGState()
        if isFrozenBand {
            // The edge of the frozen band.
            Theme.ink.withAlphaComponent(0.28).setFill()
            NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
        }
    }

    override func mouseDown(with e: NSEvent) { grid?.paneMouseDown(e) }
    override func menu(for event: NSEvent) -> NSMenu? { grid?.cellMenu(for: event) }
    override func magnify(with e: NSEvent) { grid?.magnify(with: e) }
    override func scrollWheel(with e: NSEvent) {
        if isFrozenBand { grid?.scroll.scrollWheel(with: e) } else { super.scrollWheel(with: e) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the in-place editor keeps its own events.
        guard let v = super.hitTest(point) else { return nil }
        var p: NSView? = v
        while let x = p, x !== self { if x is CellEditor { return v }; p = x.superview }
        return self
    }
}

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

/// In-place cell editor. Return commits and moves down, Tab moves right, Esc cancels.
final class CellEditor: NSTextField, NSTextFieldDelegate {
    var onFinish: ((_ text: String?, _ move: GridPoint) -> Void)?
    private var finished = false

    init(fontSize: CGFloat = 12) {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = true
        backgroundColor = Theme.sheet
        focusRingType = .none
        font = .systemFont(ofSize: fontSize)
        lineBreakMode = .byClipping
        usesSingleLineMode = true
        cell?.isScrollable = true
        wantsLayer = true
        layer?.borderColor = Theme.emberNS.cgColor
        layer?.borderWidth = 2
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    private func finish(_ text: String?, _ move: GridPoint) {
        guard !finished else { return }
        finished = true
        onFinish?(text, move)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): finish(stringValue, GridPoint(row: 1, col: 0)); return true
        case #selector(NSResponder.insertTab(_:)): finish(stringValue, GridPoint(row: 0, col: 1)); return true
        case #selector(NSResponder.insertBacktab(_:)): finish(stringValue, GridPoint(row: 0, col: -1)); return true
        case #selector(NSResponder.cancelOperation(_:)): finish(nil, GridPoint(row: 0, col: 0)); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere commits without moving.
        finish(stringValue, GridPoint(row: 0, col: 0))
    }
}
