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
    var colPos: [Int] = []  // sheet column → index in `cols`, -1 when hidden
    var xs: [CGFloat] = [0]  // left edge of each shown column, plus the total width
    var ys: [CGFloat] = [0]  // top edge of each view row, plus the total height
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
