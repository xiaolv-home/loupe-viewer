import AppKit
import LoupeCore

/// A merged range as laid out on screen (view rows).
struct MergeView {
    var m: MergeRange
    var vr0: Int
    var vr1: Int
}

/// Base sizes before zoom, in Excel's on-screen pixel units (column width chars × 7 + 5,
/// row height points × 4/3) so proportions match the original.
enum SheetMetrics {
    static let ptToPx: CGFloat = 4.0 / 3.0
    static func columnPx(chars: Double) -> CGFloat { max(16, min(1200, CGFloat(chars) * 7 + 5)) }
    static func chars(px: CGFloat) -> Double { Double(max(0, (px - 5) / 7)) }
    static let fontScale: CGFloat = 1.15
    static let padX: CGFloat = 4
}

/// Geometry: column widths, row heights (including auto-fit for wrapped text), the frozen
/// header band and where merged ranges sit on screen.
extension SpreadsheetRenderer {
    // MARK: Layout

    /// Column widths from the content for sheets without stored widths (CSV, ODS…).
    func rebuildAutoWidths() {
        autoWidths = [:]
        let s = sheet
        guard s.columnCount > 0 else { return }
        let f = NSFont.systemFont(ofSize: 11 * SheetMetrics.fontScale)
        let bold = NSFont.systemFont(ofSize: 11 * SheetMetrics.fontScale, weight: .semibold)
        let sample = visible.prefix(200)
        let header = query.headerRowIndex
        for c in 0..<s.columnCount where s.columnWidths[c] == nil {
            var w: CGFloat = 0
            for r in sample {
                let t = workbook.formatted(sheetIndex, r, c).text.prefix(60)
                if t.isEmpty { continue }
                w = max(w, (String(t) as NSString).size(withAttributes: [.font: r == header ? bold : f]).width + 16)
            }
            autoWidths[c] = min(320, max(64, w))
        }
    }

    /// Heights for rows that hold wrapped text and were not sized by hand (Excel auto-fits those).
    func rebuildFitHeights() {
        fitHeights = [:]
        let s = sheet
        // Rich text with a larger run: rows not sized by hand grow to fit it, as in Excel.
        for (key, runs) in s.richText {
            let r = key / 16384, c = key % 16384
            guard !s.customHeightRows.contains(r), let biggest = runs.compactMap(\.size).max(), biggest > 11 else { continue }
            let font = NSFont.systemFont(ofSize: CGFloat(min(48, biggest)) * SheetMetrics.fontScale)
            let lines = workbook.style(sheetIndex, r, c)?.wrap == true ? max(1, runs.map(\.text).joined().components(separatedBy: "\n").count) : 1
            fitHeights[r] = max(fitHeights[r] ?? 0, ceil(font.ascender - font.descender + font.leading) * CGFloat(lines) + 6)
        }
        guard workbook.styles.contains(where: { $0.wrap }) else { return }
        var budget = 20_000
        for (key, id) in s.styleIDs where id < workbook.styles.count && workbook.styles[id].wrap {
            let r = key / 16384, c = key % 16384
            if s.customHeightRows.contains(r) || mergeCovered.contains(key) { continue }
            var width = colWidthPx(c)
            if let m = mergeTopLeft[key] {
                if m.r1 > m.r0 { continue }
                width = (m.c0...m.c1).reduce(0) { $0 + colWidthPx($1) }
            }
            let text = workbook.formatted(sheetIndex, r, c).text
            if text.isEmpty { continue }
            budget -= 1
            if budget == 0 { break }
            let size = workbook.styles[id].fontSize.map { CGFloat($0) * SheetMetrics.fontScale } ?? 11 * SheetMetrics.fontScale
            let font = NSFont.systemFont(ofSize: size, weight: workbook.styles[id].bold ? .semibold : .regular)
            let h = (text as NSString).boundingRect(with: NSSize(width: max(10, width - SheetMetrics.padX * 2), height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: font]).height + 6
            fitHeights[r] = max(fitHeights[r] ?? 0, ceil(h))
        }
    }

    func colWidthPx(_ c: Int) -> CGFloat {
        if let cw = sheet.columnWidths[c] ?? sheet.defaultColumnWidth { return SheetMetrics.columnPx(chars: cw) }
        return autoWidths[c] ?? 72
    }

    func rowHeightPx(_ sr: Int) -> CGFloat {
        let s = sheet
        let fallback: CGFloat = workbook.csv != nil ? 22 : 20
        let base = s.rowHeights[sr].map { CGFloat($0) * SheetMetrics.ptToPx } ?? s.defaultRowHeight.map { CGFloat($0) * SheetMetrics.ptToPx } ?? fallback
        if s.customHeightRows.contains(sr) { return max(2, min(1200, base)) }
        return min(1200, max(base, fitHeights[sr] ?? 0))
    }

    func rebuildLayout() {
        let s = sheet, q = query
        var L = GridLayout()
        L.cols = (0..<s.columnCount).filter { !q.hiddenColumns.contains($0) }
        L.colPos = Array(repeating: -1, count: s.columnCount)
        for (i, c) in L.cols.enumerated() { L.colPos[c] = i }
        L.xs.reserveCapacity(L.cols.count + 1)
        for c in L.cols { L.xs.append(L.xs[L.xs.count - 1] + (colWidthPx(c) * zoom).rounded()) }
        L.ys.reserveCapacity(visible.count + 1)
        for sr in visible { L.ys.append(L.ys[L.ys.count - 1] + max(1, (rowHeightPx(sr) * zoom).rounded())) }
        // Header rows (and the title rows above them) stay on top, unless they would fill the view.
        var k = 0
        if let h = q.headerRowIndex { while k < visible.count && visible[k] <= h { k += 1 } }
        let room = max(grid.bounds.height, 500) - GridView.headerHeight
        if k > 0 && L.ys[k] > room * 0.42 { k = 0 }
        L.frozenRows = k
        layout = L
        viewRowOf = Array(repeating: -1, count: s.rows.count + 1)
        for (vr, sr) in visible.enumerated() where sr < viewRowOf.count { viewRowOf[sr] = vr }
        rebuildMergeViews()
    }

    func viewRow(ofSheetRow sr: Int) -> Int? {
        sr >= 0 && sr < viewRowOf.count && viewRowOf[sr] >= 0 ? viewRowOf[sr] : nil
    }

    func rebuildMerges() {
        mergeTopLeft = [:]
        mergeCovered = []
        for m in sheet.merges where (m.r1 - m.r0 + 1) * (m.c1 - m.c0 + 1) <= 200_000 {
            mergeTopLeft[Sheet.key(m.r0, m.c0)] = m
            for r in m.r0...m.r1 { for c in m.c0...m.c1 where !(r == m.r0 && c == m.c0) { mergeCovered.insert(Sheet.key(r, c)) } }
        }
    }

    /// Merges whose rows sit together on screen are drawn as one area; when sorting or
    /// filtering scatters them, the top-left cell is drawn on its own.
    func rebuildMergeViews() {
        mergeViews = []
        activeMerges = [:]
        for m in sheet.merges where mergeTopLeft[Sheet.key(m.r0, m.c0)] != nil {
            let vrs = (m.r0...m.r1).compactMap { viewRow(ofSheetRow: $0) }
            guard let a = vrs.first, let b = vrs.last, b - a == vrs.count - 1 else { continue }
            mergeViews.append(MergeView(m: m, vr0: a, vr1: b))
            activeMerges[Sheet.key(m.r0, m.c0)] = mergeViews.count - 1
        }
    }

    func mergeRect(_ mv: MergeView) -> NSRect? {
        let L = layout
        var p0: Int?, p1: Int?
        for c in mv.m.c0...mv.m.c1 { if let p = L.position(of: c) { if p0 == nil { p0 = p }; p1 = p } }
        guard let a = p0, let b = p1, mv.vr1 < L.rowCount else { return nil }
        return NSRect(x: L.xs[a], y: L.ys[mv.vr0], width: L.xs[b + 1] - L.xs[a], height: L.ys[mv.vr1 + 1] - L.ys[mv.vr0])
    }

    /// Grid rectangle of a cell, widened to its merged area when it is a merge's top-left.
    func cellArea(row: Int, col: Int) -> NSRect? {
        guard row < visible.count else { return nil }
        if let i = activeMerges[Sheet.key(visible[row], col)], let r = mergeRect(mergeViews[i]) { return r }
        return layout.rect(row: row, col: col)
    }

    /// Grows a selection until no merged area sticks out of it.
    func expandedToMerges(_ g: GridRect) -> GridRect {
        guard !mergeViews.isEmpty else { return g }
        var g = g
        var changed = true
        while changed {
            changed = false
            for mv in mergeViews where mv.vr0 <= g.r1 && mv.vr1 >= g.r0 && mv.m.c0 <= g.c1 && mv.m.c1 >= g.c0 {
                if mv.vr0 < g.r0 { g.r0 = mv.vr0; changed = true }
                if mv.vr1 > g.r1 { g.r1 = mv.vr1; changed = true }
                if mv.m.c0 < g.c0 { g.c0 = mv.m.c0; changed = true }
                if mv.m.c1 > g.c1 { g.c1 = mv.m.c1; changed = true }
            }
        }
        return g
    }

    func gridMergeArea(row: Int, col: Int) -> GridRect? { mergeArea(row: row, col: col)?.area }

    /// The merged range a cell belongs to, as its top-left point and the whole area (view rows).
    func mergeArea(row: Int, col: Int) -> (topLeft: GridPoint, area: GridRect)? {
        guard row >= 0, row < visible.count else { return nil }
        let key = Sheet.key(visible[row], col)
        guard mergeCovered.contains(key) || activeMerges[key] != nil else { return nil }
        let sr = visible[row]
        guard let mv = mergeViews.first(where: { $0.m.r0 <= sr && sr <= $0.m.r1 && $0.m.c0 <= col && col <= $0.m.c1 }) else { return nil }
        let tl = GridPoint(row: mv.vr0, col: mv.m.c0)
        return (tl, GridRect(tl, GridPoint(row: mv.vr1, col: mv.m.c1)))
    }
}

