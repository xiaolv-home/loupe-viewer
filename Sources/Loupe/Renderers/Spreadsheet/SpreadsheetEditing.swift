import AppKit
import UniformTypeIdentifiers
import LoupeCore

/// In-place editing, undo of cell edits, and writing the document to disk.
extension SpreadsheetRenderer {
    // MARK: Editing

    func gridBeginEdit(_ p: GridPoint, typed: String?) {
        guard editingEnabled else { return }
        let p = mergeArea(row: p.row, col: p.col)?.topLeft ?? p
        guard viewMode == 0, p.row < visible.count, p.col >= 0, layout.position(of: p.col) != nil else { return }
        endEditing(commit: true)
        gridSelect([GridRect(p, p)], active: p, anchor: p)
        grid.scrollTo(row: p.row, col: p.col)
        grid.layoutSubtreeIfNeeded()
        guard let (hostView, cellRect) = grid.editorHost(row: p.row, col: p.col) else { return }
        let sr = visible[p.row]
        let e = CellEditor(fontSize: 12 * zoom)
        e.stringValue = typed ?? (sheet.formulas[Sheet.key(sr, p.col)] ?? sheet.cell(sr, p.col).editText)
        var rect = cellRect
        if let area = cellArea(row: p.row, col: p.col) { rect.size = area.size }
        rect.size.width = max(rect.width, 120)
        let h = ceil(22 * zoom)
        rect.origin.y += max(0, (rect.height - h) / 2)
        rect.size.height = min(max(rect.height, h), h)
        e.frame = rect
        e.onFinish = { [weak self] text, move in
            guard let self else { return }
            self.editor?.removeFromSuperview()
            self.editor = nil
            if let text { self.writeCell(row: sr, col: p.col, input: text) }
            let L = self.layout
            let pos = max(0, min(L.cols.count - 1, (L.position(of: p.col) ?? 0) + move.col))
            let next = GridPoint(row: max(0, min(self.visible.count - 1, p.row + move.row)), col: L.cols.isEmpty ? p.col : L.cols[pos])
            self.gridSelect([GridRect(next, next)], active: next, anchor: next)
            self.grid.scrollTo(row: next.row, col: next.col)
            self.grid.window?.makeFirstResponder(self.grid)
        }
        hostView.addSubview(e)
        editor = e
        grid.window?.makeFirstResponder(e)
        if typed != nil, let fe = e.currentEditor() { fe.selectedRange = NSRange(location: (e.stringValue as NSString).length, length: 0) }
    }

    func endEditing(commit: Bool) {
        guard let e = editor else { return }
        if commit { e.window?.makeFirstResponder(grid) } else { e.removeFromSuperview(); editor = nil }
    }

    func writeCell(row: Int, col: Int, input: String) {
        let old = sheet.formulas[Sheet.key(row, col)] ?? sheet.cell(row, col).editText
        guard input != old else { return }
        let (v, f) = doc.parseInput(input, sheet: sheetIndex, row: row, col: col)
        apply([CellChange(sheet: sheetIndex, row: row, col: col, value: v, formula: f)], name: "编辑单元格")
    }

    func gridClearSelection() {
        guard viewMode == 0, editingEnabled else { return }
        var changes: [CellChange] = []
        let cols = Set(gridVisibleColumns())
        for rect in rects {
            for r in rect.r0...min(rect.r1, visible.count - 1) where r >= 0 {
                for c in rect.c0...rect.c1 where cols.contains(c) {
                    let sr = visible[r]
                    if !sheet.cell(sr, c).isEmpty || sheet.formulas[Sheet.key(sr, c)] != nil {
                        changes.append(CellChange(sheet: sheetIndex, row: sr, col: c, value: .empty, formula: nil))
                    }
                    if changes.count > 1_000_000 { break }
                }
            }
        }
        apply(changes, name: "清除内容")
    }

    func gridPaste(_ text: String) {
        guard viewMode == 0, editingEnabled, active.row < visible.count else { return }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let sep: Character = text.contains("\t") ? "\t" : ","
        var changes: [CellChange] = []
        for (i, line) in lines.enumerated() {
            // Rows paste downward through the *visible* rows, so a filtered view stays consistent.
            let vr = active.row + i
            let sr = vr < visible.count ? visible[vr] : (visible.last ?? 0) + (vr - visible.count + 1)
            for (j, field) in line.split(separator: sep, omittingEmptySubsequences: false).enumerated() {
                let (v, f) = doc.parseInput(String(field), sheet: sheetIndex, row: sr, col: active.col + j)
                changes.append(CellChange(sheet: sheetIndex, row: sr, col: active.col + j, value: v, formula: f))
            }
            if changes.count > 1_000_000 { break }
        }
        apply(changes, name: "粘贴")
    }

    /// Applies changes, records undo and refreshes the grid.
    func apply(_ changes: [CellChange], name: String) {
        guard !changes.isEmpty else { return }
        let rowsBefore = sheet.rows.count, colsBefore = sheet.columnCount
        let undo = doc.apply(changes)
        if let um = grid.window?.undoManager {
            um.registerUndo(withTarget: self) { r in r.apply(undo, name: name) }
            um.setActionName(name)
        }
        markDirty()
        // New rows/columns, or wrapped text that may change its row's height, need a new layout.
        if sheet.rows.count != rowsBefore || sheet.columnCount != colsBefore
            || changes.contains(where: { workbook.style($0.sheet, $0.row, $0.col)?.wrap == true }) {
            reloadSheet()
        } else {
            lookCache = [:]
            grid.redrawAll()
        }
        gridSelect(rects, active: active, anchor: anchor)
    }

    /// Mirrors the document's unsaved state onto the window (dot in the close button, status line).
    func markDirty() {
        dirty = doc.hasChanges
        host?.window?.isDocumentEdited = dirty
        host?.rendererDidUpdate()
    }

    func markSaved() {
        doc.markSaved()
        grid.window?.undoManager?.removeAllActions(withTarget: self)
        markDirty()
    }

    /// Formula bar Return: write into the active cell (Excel behaviour) and show the result.
    func commitFormulaBar() {
        guard active.row < visible.count else { return }
        let sr = visible[active.row]
        writeCell(row: sr, col: active.col, input: formulaText)
        let v = sheet.cell(sr, active.col)
        if formulaText.hasPrefix("=") {
            resultIsError = { if case .error = v { return true }; return false }()
            resultText = workbook.formatted(sheetIndex, sr, active.col).text
        }
        grid.window?.makeFirstResponder(grid)
    }

    // MARK: Saving

    var canSaveInPlace: Bool {
        guard let f = file else { return false }
        if workbook.csv != nil { return true }
        return saveBase == f.url && SpreadsheetDocument.canWriteInPlace(f.url, isCSV: false)
    }

    /// ⌘S. Formats that cannot be written back (xls, Numbers, ODS) go through “另存为”.
    func save(completion: ((Bool) -> Void)? = nil) {
        endEditing(commit: true)
        guard let f = file else { completion?(false); return }
        guard canSaveInPlace else { saveAs(completion: completion); return }
        write(to: f.url, reopen: false, completion: completion)
    }

    func saveAs(completion: ((Bool) -> Void)? = nil) {
        endEditing(commit: true)
        guard let f = file, let window = grid.window else { completion?(false); return }
        let panel = NSSavePanel()
        let isCSV = workbook.csv != nil
        panel.allowedContentTypes = isCSV ? [.commaSeparatedText, UTType(filenameExtension: "xlsx")!] : [UTType(filenameExtension: "xlsx")!, .commaSeparatedText]
        panel.allowsOtherFileTypes = false
        panel.directoryURL = f.url.deletingLastPathComponent()
        panel.nameFieldStringValue = f.url.deletingPathExtension().lastPathComponent + (isCSV ? ".csv" : (canSaveInPlace ? " 副本.xlsx" : ".xlsx"))
        panel.message = isCSV ? "保存为 CSV 或 Excel" : "保存为 Excel（.xlsx，保留原格式）或 CSV（仅当前工作表的值）"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let dest = panel.url else { completion?(false); return }
            self.write(to: dest, reopen: true, completion: completion)
        }
    }

    /// Writes off the main thread; the original is replaced only after the result reads back.
    func write(to dest: URL, reopen: Bool = true, completion: ((Bool) -> Void)?) {
        let snapshot = doc, si = sheetIndex, base = saveBase
        host?.reportProgress(nil, label: "正在保存…")
        Task { [weak self] in
            do {
                let keptEncoding = try await Task.detached(priority: .userInitiated) {
                    try snapshot.write(to: dest, base: base, sheet: si)
                }.value
                guard let self else { return }
                self.host?.reportProgress(nil, label: nil)
                self.markSaved()
                completion?(true)
                if reopen {
                    self.host?.open(dest)
                } else if !keptEncoding {
                    self.doc.workbook.csv?.encoding = .utf8
                    self.doc.workbook.csv?.bom = true
                    self.host?.showNotice("已保存。部分字符无法用原编码表示，文件已改为 UTF-8 编码。", style: .warning, action: nil)
                } else {
                    self.flash("已保存到原文件")
                }
            } catch {
                self?.host?.reportProgress(nil, label: nil)
                Log.write("save failed: \(error)")
                self?.host?.showNotice("保存失败：\(error.localizedDescription)。原文件没有被改动。", style: .warning, action: nil)
                completion?(false)
            }
        }
    }

    /// Exports what is on screen: visible rows in their current order and visible columns.
    func export(asCSV: Bool) {
        guard let f = file, let window = grid.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asCSV ? .commaSeparatedText : UTType(filenameExtension: "xlsx")!]
        panel.directoryURL = f.url.deletingLastPathComponent()
        panel.nameFieldStringValue = f.url.deletingPathExtension().lastPathComponent + " 导出." + (asCSV ? "csv" : "xlsx")
        panel.message = "导出当前视图（已应用的筛选、排序、隐藏和计算列）"
        let cols = gridVisibleColumns()
        let rows: [[CellValue]] = visible.map { r in cols.map { sheet.cell(r, $0) } }
        let name = sheet.name
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let dest = panel.url else { return }
            do {
                if asCSV { try CSVWriter.write(rows: rows, format: CSVFormat(delimiter: 44, encoding: .utf8, bom: true, crlf: true), to: dest) }
                else { try XLSXWriter.write(sheets: [(name: name, rows: rows, formulas: [:])], to: dest) }
                self?.host?.showNotice("已导出 \(Fmt.number(rows.count)) 行：\(dest.lastPathComponent)", style: .success,
                                       action: NoticeAction(title: "在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([dest]) })
            } catch {
                self?.host?.showNotice("导出失败：\(error.localizedDescription)", style: .warning, action: nil)
            }
        }
    }

    func flash(_ text: String) {
        host?.showNotice(text, style: .success, action: nil)
    }
}
