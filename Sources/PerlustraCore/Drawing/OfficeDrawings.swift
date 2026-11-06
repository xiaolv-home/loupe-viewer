import Foundation

/// Connects a worksheet to what is drawn over it, and gives the drawings room on the grid.
enum OfficeDrawings {
    /// The drawings of a worksheet or chart sheet (`<drawing r:id>` → its drawing part).
    static func sheetDrawings(sheetXML: Data, sheetPath: String, theme: DrawingTheme, parts: [String: Data]) -> [SheetDrawing] {
        let head = String(decoding: sheetXML.suffix(64 << 10), as: UTF8.self)
        guard let r = head.range(of: #"<(\w+:)?drawing\b[^>]*?\b(\w+:)?id="([^"]+)""#, options: .regularExpression) else { return [] }
        let tag = String(head[r])
        guard let idRange = tag.range(of: #"id="[^"]+""#, options: .regularExpression) else { return [] }
        let id = String(tag[idRange].dropFirst(4).dropLast())
        let rels = OfficeRels.parse(parts[OfficeRels.relsPath(for: sheetPath)], base: sheetPath)
        guard let path = rels[id], let data = parts[path] else { return [] }
        return DrawingParser.parse(data, path: path, theme: theme) { parts[$0] }
    }

    // Excel's default cell size in its screen pixels (8.43 characters × 7 + 5, 15 pt × 4/3).
    static func columnPixels(_ sheet: Sheet, _ c: Int) -> Double {
        let chars = sheet.columnWidths[c] ?? sheet.defaultColumnWidth ?? 8.43
        return max(16, chars * 7 + 5)
    }

    static func rowPixels(_ sheet: Sheet, _ r: Int) -> Double {
        (sheet.rowHeights[r] ?? sheet.defaultRowHeight ?? 15) * 4 / 3
    }

    /// The last row and column a drawing reaches.
    static func extent(_ d: SheetDrawing, in sheet: Sheet) -> (row: Int, col: Int) {
        let a = d.anchor
        if let to = a.to { return (to.row, to.col) }
        var row = a.from?.row ?? 0, col = a.from?.col ?? 0
        var y = a.from.map { -$0.rowOffset } ?? -(a.y ?? 0)
        var x = a.from.map { -$0.colOffset } ?? -(a.x ?? 0)
        let h = a.height ?? 0, w = a.width ?? 0
        while row < 1_048_575 { y += rowPixels(sheet, row); if y >= h { break }; row += 1 }
        while col < 16_383 { x += columnPixels(sheet, col); if x >= w { break }; col += 1 }
        return (row, col)
    }

    /// Adds empty rows and columns so drawings beyond the cells in use still have a place on
    /// the grid (a sheet holding only a chart would otherwise show nothing at all).
    static func makeRoom(for sheet: inout Sheet) {
        guard !sheet.drawings.isEmpty else { return }
        var lastRow = sheet.rows.count - 1, lastCol = sheet.columnCount - 1
        for d in sheet.drawings {
            let e = extent(d, in: sheet)
            lastRow = max(lastRow, min(e.row + 1, 10_000))
            lastCol = max(lastCol, min(e.col + 1, 1_000))
        }
        while sheet.rows.count <= lastRow { sheet.rows.append([]) }
        sheet.columnCount = max(sheet.columnCount, lastCol + 1)
    }

    /// A chart sheet has no cells: lay a plain grid under its chart.
    static func fitChartSheet(_ sheet: inout Sheet) {
        sheet.defaultColumnWidth = 8.43
        sheet.defaultRowHeight = 15
        makeRoom(for: &sheet)
    }
}
