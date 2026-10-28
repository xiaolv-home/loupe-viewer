import Foundation

/// One cell's content before/after an edit (sheet coordinates).
public struct CellChange: Sendable, Equatable {
    public var sheet: Int, row: Int, col: Int
    public var value: CellValue
    public var formula: String?
    public init(sheet: Int, row: Int, col: Int, value: CellValue, formula: String?) {
        self.sheet = sheet; self.row = row; self.col = col; self.value = value; self.formula = formula
    }
}

/// An open workbook plus everything changed since it was last saved: edited cells,
/// inserted/deleted rows and columns, and resized rows/columns. It knows nothing about
/// views — the grid edits it, and undo keeps copies of it (it is a value).
public struct SpreadsheetDocument: Sendable {
    public var workbook: Workbook
    public private(set) var edited: [Int: Set<Int>] = [:]
    public private(set) var structure: [Int: [StructOp]] = [:]
    public private(set) var layoutEdits: [Int: SheetLayoutEdits] = [:]
    /// Sheets whose merged cells were merged or unmerged by hand.
    public private(set) var mergesChanged: Set<Int> = []

    public init(workbook: Workbook) { self.workbook = workbook }

    public var hasChanges: Bool {
        edited.values.contains { !$0.isEmpty } || structure.values.contains { !$0.isEmpty }
            || layoutEdits.values.contains { !$0.isEmpty } || !mergesChanged.isEmpty
    }

    public mutating func markSaved() {
        edited = [:]
        structure = [:]
        layoutEdits = [:]
        mergesChanged = []
    }

    // MARK: Cells

    /// Interprets typed input like a spreadsheet: "=…" formula, dates for date-formatted
    /// cells, TRUE/FALSE, numbers, else text.
    public func parseInput(_ text: String, sheet si: Int, row: Int, col: Int) -> (CellValue, String?) {
        let t = text.trimmingCharacters(in: .newlines)
        if t.hasPrefix("="), t.count > 1 { return (.empty, t) }
        if t.isEmpty { return (.empty, nil) }
        if let fmt = workbook.style(si, row, col)?.numberFormat, StylesParser.isDateFormat(fmt), let d = CellValue.parseDate(t) { return (.date(d), nil) }
        if case .date = workbook.sheets[si].cell(row, col), let d = CellValue.parseDate(t) { return (.date(d), nil) }
        if ["TRUE", "FALSE"].contains(t.uppercased()) { return (.bool(t.uppercased() == "TRUE"), nil) }
        return (CellValue.infer(t), nil)
    }

    /// Writes cells, evaluates new formulas and refreshes dependent ones.
    /// Returns the changes that undo this one (apply them in that order).
    @discardableResult
    public mutating func apply(_ changes: [CellChange]) -> [CellChange] {
        var undo: [CellChange] = []
        undo.reserveCapacity(changes.count)
        for ch in changes {
            var s = workbook.sheets[ch.sheet]
            let key = Sheet.key(ch.row, ch.col)
            undo.append(CellChange(sheet: ch.sheet, row: ch.row, col: ch.col, value: s.cell(ch.row, ch.col), formula: s.formulas[key]))
            while s.rows.count <= ch.row { s.rows.append([]) }
            while s.rows[ch.row].count <= ch.col { s.rows[ch.row].append(.empty) }
            s.rows[ch.row][ch.col] = ch.value
            s.formulas[key] = ch.formula
            if ch.col >= s.columnCount { s.columnCount = ch.col + 1 }
            workbook.sheets[ch.sheet] = s
            edited[ch.sheet, default: []].insert(key)
        }
        for ch in changes where ch.formula != nil {
            let v = FormulaEngine.evaluate(ch.formula!, in: FormulaContext(workbook: workbook, sheet: ch.sheet))
            workbook.sheets[ch.sheet].rows[ch.row][ch.col] = v.cell
        }
        recalculate()
        return undo.reversed()
    }

    /// Re-evaluates the workbook's formulas. Results Loupe's engine cannot produce
    /// (unsupported functions) keep the value Excel stored. Large workbooks are left alone.
    public mutating func recalculate(limit: Int = 5000) {
        let total = workbook.sheets.reduce(0) { $0 + $1.formulas.count }
        guard total > 0, total <= limit else { return }
        for _ in 0..<2 {
            for si in workbook.sheets.indices {
                for (k, f) in workbook.sheets[si].formulas.sorted(by: { $0.key < $1.key }) {
                    let v = FormulaEngine.evaluate(f, in: FormulaContext(workbook: workbook, sheet: si))
                    if case .error(let e) = v, e.hasPrefix("#NAME?") || e.hasPrefix("#ERROR") { continue }
                    let r = k / 16384, c = k % 16384
                    guard r < workbook.sheets[si].rows.count, c < workbook.sheets[si].rows[r].count else { continue }
                    workbook.sheets[si].rows[r][c] = v.cell
                }
            }
        }
    }

    // MARK: Rows and columns

    /// Inserts/deletes rows or columns of one sheet. Pending edits and size changes move with
    /// their cells; every formula will be written out again on save (moved references stay
    /// right, shared formulas become plain ones).
    public mutating func perform(_ ops: [StructOp], sheet si: Int) {
        for op in ops {
            workbook.apply(op, sheet: si)
            structure[si, default: []].append(op)
            if let keys = edited[si] {
                edited[si] = Set(keys.compactMap { k in
                    let r = k / 16384, c = k % 16384
                    if op.isRowOp { return op.map(r).map { Sheet.key($0, c) } }
                    return op.map(c).map { Sheet.key(r, $0) }
                })
            }
            if var lay = layoutEdits[si] {
                if op.isRowOp { lay.rows = Set(lay.rows.compactMap(op.map)) } else { lay.cols = Set(lay.cols.compactMap(op.map)) }
                layoutEdits[si] = lay
            }
            // Inserted cells that carry formatting must be written out to keep it.
            switch op {
            case .insertRows(let at, let n):
                for k in workbook.sheets[si].styleIDs.keys where (at..<at + n).contains(k / 16384) { edited[si, default: []].insert(k) }
            case .insertColumns(let at, let n):
                for k in workbook.sheets[si].styleIDs.keys where (at..<at + n).contains(k % 16384) { edited[si, default: []].insert(k) }
            default: break
            }
        }
        for i in workbook.sheets.indices where !workbook.sheets[i].formulas.isEmpty {
            edited[i, default: []].formUnion(workbook.sheets[i].formulas.keys)
        }
        recalculate()
    }

    /// Formulas anywhere in the workbook that lost a target (#REF!).
    public var brokenReferenceCount: Int {
        workbook.sheets.reduce(0) { $0 + $1.formulas.values.filter { $0.contains("#REF!") }.count }
    }

    // MARK: Merged cells

    /// Non-empty cells other than the top-left that merging `m` would clear (Excel keeps only
    /// the top-left value).
    public func cellsClearedByMerging(_ m: MergeRange, sheet si: Int) -> Int {
        let s = workbook.sheets[si]
        var n = 0
        for r in m.r0...m.r1 { for c in m.c0...m.c1 where !(r == m.r0 && c == m.c0) {
            if !s.cell(r, c).isEmpty || s.formulas[Sheet.key(r, c)] != nil { n += 1 }
        } }
        return n
    }

    /// Merges a range: existing merges inside or overlapping it are absorbed, and every
    /// cell but the top-left is emptied.
    public mutating func merge(_ m: MergeRange, sheet si: Int) {
        guard m.r1 > m.r0 || m.c1 > m.c0 else { return }
        var clear: [CellChange] = []
        let s = workbook.sheets[si]
        for r in m.r0...m.r1 { for c in m.c0...m.c1 where !(r == m.r0 && c == m.c0) {
            if !s.cell(r, c).isEmpty || s.formulas[Sheet.key(r, c)] != nil {
                clear.append(CellChange(sheet: si, row: r, col: c, value: .empty, formula: nil))
            }
        } }
        if !clear.isEmpty { apply(clear) }
        workbook.sheets[si].merges.removeAll { $0.overlaps(m) }
        workbook.sheets[si].merges.append(m)
        mergesChanged.insert(si)
    }

    /// Unmerges every merged range that overlaps `area`; returns how many were split.
    @discardableResult
    public mutating func unmerge(_ area: MergeRange, sheet si: Int) -> Int {
        let before = workbook.sheets[si].merges.count
        workbook.sheets[si].merges.removeAll { $0.overlaps(area) }
        let n = before - workbook.sheets[si].merges.count
        if n > 0 { mergesChanged.insert(si) }
        return n
    }

    // MARK: Sizes

    /// Sets a column width (Excel character units). With `persist` false (or in a text file,
    /// which has no widths) it only changes the view and is not a change to save.
    public mutating func setColumnWidth(_ chars: Double, sheet si: Int, column c: Int, persist: Bool = true) {
        workbook.sheets[si].columnWidths[c] = chars
        if persist && workbook.csv == nil { layoutEdits[si, default: SheetLayoutEdits()].cols.insert(c) }
    }

    /// Sets a row height in points, marking it as sized by hand.
    public mutating func setRowHeight(_ points: Double, sheet si: Int, row r: Int, persist: Bool = true) {
        workbook.sheets[si].rowHeights[r] = points
        workbook.sheets[si].customHeightRows.insert(r)
        if persist && workbook.csv == nil { layoutEdits[si, default: SheetLayoutEdits()].rows.insert(r) }
    }

    // MARK: Saving

    /// True when the original file can take the changes directly (CSV, or an .xlsx we patch).
    public static func canWriteInPlace(_ url: URL, isCSV: Bool) -> Bool {
        isCSV || ["xlsx", "xlsm", "xltx"].contains(url.pathExtension.lowercased())
    }

    /// Writes the document to `dest`. CSV/TSV destinations get the values of `sheet`; .xlsx
    /// destinations patch `base` (keeping all formatting) or, without one, become a new workbook.
    /// Returns false when a CSV had to fall back to UTF-8 because its encoding could not hold
    /// some characters. Runs on any thread.
    public func write(to dest: URL, base: URL?, sheet si: Int) throws -> Bool {
        let ext = dest.pathExtension.lowercased()
        if ["csv", "tsv", "txt", "tab"].contains(ext) {
            let fmt = workbook.csv ?? CSVFormat(delimiter: ext == "tsv" ? 9 : 44, encoding: .utf8, bom: true, crlf: true)
            return try CSVWriter.write(rows: workbook.sheets[si].rows, format: fmt, to: dest)
        }
        if let base {
            try XLSXPatcher.save(base: base, to: dest, workbook: workbook, edited: edited, structure: structure,
                                 layout: layoutEdits, mergesChanged: mergesChanged)
        } else {
            try XLSXWriter.write(sheets: workbook.sheets.map { (name: $0.name, rows: $0.rows, formulas: $0.formulas) }, to: dest)
        }
        return true
    }
}

extension SheetQuery {
    /// Keeps the header row, hidden rows/columns, filters and sort pointing at the same
    /// cells after rows or columns were inserted or deleted.
    public mutating func apply(_ op: StructOp) {
        if op.isRowOp {
            if let h = headerRowIndex { headerRowIndex = op.map(h) }
            hiddenRows = Set(hiddenRows.compactMap(op.map))
        } else {
            hiddenColumns = Set(hiddenColumns.compactMap(op.map))
            var f: [Int: FilterRule] = [:]
            for (c, rule) in filters { if let nc = op.map(c) { f[nc] = rule } }
            filters = f
            sortColumn = sortColumn.flatMap(op.map)
        }
    }
}
