import AppKit
import UniformTypeIdentifiers
import LoupeCore

/// The calculator bar: formulas over this workbook and other files ([门店表.xlsx]Sheet1!A:C),
/// computed for a look or applied to every row as an on-screen column — the file is not changed.
extension SpreadsheetRenderer {
    // MARK: Calculating

    var editingEnabled: Bool { AppSettings.shared.spreadsheetEditing }
    var gridEditable: Bool { editingEnabled }

    /// Return in the calculator: the result appears beside it.
    func calculate() {
        let t = normalizedCalc
        guard !t.isEmpty else { resultText = ""; return }
        let wb = workbook, si = sheetIndex
        Task { [weak self] in
            guard let self else { return }
            let books = await self.externalBooks(for: t)
            let v = await Task.detached(priority: .userInitiated) {
                FormulaEngine.evaluate(t, in: FormulaContext(workbook: wb, sheet: si, externalWorkbooks: books))
            }.value
            self.resultIsError = v.isErrorValue
            self.resultText = v.display
        }
    }

    /// "SUM(A1:A3)" and "=SUM(A1:A3)" both work.
    var normalizedCalc: String {
        let t = calcText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        return t.hasPrefix("=") ? t : "=" + t
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
    }

    /// Adds the selected cells to the calculator as a reference ("D2:D30", "B:B", "A5").
    func insertSelectionReference() {
        guard let g = rects.last, !visible.isEmpty else { return }
        let r0 = visible[max(0, min(g.r0, visible.count - 1))] + 1, r1 = visible[max(0, min(g.r1, visible.count - 1))] + 1
        let wholeColumns = g.r0 == 0 && g.r1 >= visible.count - 1 && visible.count > 1
        let ref: String
        if wholeColumns { ref = "\(Sheet.columnName(g.c0)):\(Sheet.columnName(g.c1))" }
        else if g.cellCount == 1 { ref = "\(Sheet.columnName(g.c0))\(r0)" }
        else { ref = "\(Sheet.columnName(g.c0))\(r0):\(Sheet.columnName(g.c1))\(r1)" }
        appendToCalc(ref)
    }

    private func appendToCalc(_ piece: String) {
        var t = calcText
        if t.isEmpty { t = "=" }
        if let last = t.last, !"=(,+-*/&<>: ".contains(last) { t += "," }
        calcText = t + piece
    }

    // MARK: Other files

    /// Picks another table file and inserts a reference to one of its sheets.
    func chooseExternalFile() {
        guard let window = grid.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["xlsx", "xlsm", "csv", "tsv", "ods"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = file?.url.deletingLastPathComponent()
        panel.message = "选择要引用的表格文件（公式里写成 [文件名]工作表!区域）"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            Task {
                guard let wb = await self.loadExternal(url) else {
                    self.host?.showNotice("无法读取「\(url.lastPathComponent)」", style: .warning, action: nil)
                    return
                }
                let name = url.lastPathComponent
                self.externalURLs[name.lowercased()] = url
                self.externalCache[name.lowercased()] = wb
                let sheets = wb.sheets.filter { !$0.rows.isEmpty }
                if sheets.count <= 1, let s = sheets.first ?? wb.sheets.first {
                    self.appendToCalc(Self.externalRef(book: name, sheet: s))
                } else {
                    self.pickSheet(of: name, sheets: sheets)
                }
            }
        }
    }

    private func pickSheet(of book: String, sheets: [Sheet]) {
        guard let window = grid.window else { return }
        let m = NSMenu(title: "选择工作表")
        let head = NSMenuItem(title: "「\(book)」的工作表", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        for s in sheets {
            let i = NSMenuItem(title: "\(s.name)（\(Fmt.number(s.rows.count)) 行）", action: #selector(MenuAction.fire), keyEquivalent: "")
            let a = MenuAction { [weak self] in self?.appendToCalc(Self.externalRef(book: book, sheet: s)) }
            i.target = a
            i.representedObject = a
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: window.contentView)
    }

    /// "[门店表.xlsx]门店!A:C" — every used column; quoted when names need it.
    static func externalRef(book: String, sheet: Sheet) -> String {
        let cols = "A:\(Sheet.columnName(max(0, sheet.columnCount - 1)))"
        let prefix = "[\(book)]\(sheet.name)"
        let plain = prefix.allSatisfy { $0.isLetter || $0.isNumber || "[]._".contains($0) }
        return (plain ? prefix : "'" + prefix.replacingOccurrences(of: "'", with: "''") + "'") + "!" + cols
    }

    /// Loads the workbooks a formula names: ones picked before, else files beside this one.
    func externalBooks(for formula: String) async -> [String: Workbook] {
        var out: [String: Workbook] = [:]
        for name in FormulaEngine.externalBookNames(in: formula) {
            let key = name.lowercased()
            if let wb = externalCache[key] { out[key] = wb; continue }
            let url = externalURLs[key] ?? file?.url.deletingLastPathComponent().appendingPathComponent(name)
            if let url, let wb = await loadExternal(url) {
                externalCache[key] = wb
                out[key] = wb
            }
        }
        return out
    }

    private func loadExternal(_ url: URL) async -> Workbook? {
        await Task.detached(priority: .userInitiated) { () -> Workbook? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            switch url.pathExtension.lowercased() {
            case "csv": return try? SpreadsheetReader.readDelimited(url: url, delimiter: 44)
            case "tsv", "tab": return try? SpreadsheetReader.readDelimited(url: url, delimiter: 9)
            case "ods": return try? SpreadsheetReader.readODS(url: url)
            default: return try? SpreadsheetReader.readXLSX(url: url)
            }
        }.value
    }

    // MARK: Applying to every row

    /// Applies the calculator's formula to every data row as a new column on screen. It is read
    /// as written for the selected row; relative row references move with each row, $ ones stay.
    func fillComputedColumn() {
        let t = normalizedCalc
        guard !t.isEmpty, active.row < visible.count else { return }
        computedCount += 1
        let name = "计算\(computedCount)"
        Task { [weak self] in
            guard let self else { return }
            switch await self.appendComputedColumn(formula: t, baseRow: self.visible[self.active.row], name: name) {
            case .failure(let e):
                self.resultIsError = true
                self.resultText = e.message
            case .success(let r):
                self.host?.showNotice("已在最右边加了「\(name)」列（\(Sheet.columnName(r.column)) 列，共 \(Fmt.number(r.rows)) 行，只在屏幕上，不改原文件；可导出）"
                                      + (r.errors > 0 ? "，其中 \(r.errors) 行出错" : ""),
                                      style: r.errors > 0 ? .warning : .success, action: nil)
            }
        }
    }

    struct ComputedColumn { var column: Int; var rows: Int; var errors: Int; var sample: [CellValue] }

    /// Evaluates `formula` (written for sheet row `baseRow`) for every data row and appends the
    /// results as a new column on screen, then selects it.
    func appendComputedColumn(formula: String, baseRow: Int, name: String) async -> Result<ComputedColumn, FormulaError> {
        let expr: Expr
        do { expr = try FormulaParser.parse(formula.hasPrefix("=") ? formula : "=" + formula) } catch {
            return .failure((error as? FormulaError) ?? FormulaError(message: "公式有误"))
        }
        let wb = workbook
        let si = sheetIndex
        let first = query.firstDataRow
        let total = wb.sheets[si].rows.count
        host?.reportProgress(nil, label: "正在计算 \(Fmt.number(max(0, total - first))) 行…")
        let books = await externalBooks(for: formula)
        let values: [CellValue] = await Task.detached(priority: .userInitiated) {
            (first..<max(first, total)).map { r in
                FormulaEngine.evaluate(expr, in: FormulaContext(workbook: wb, sheet: si, rowOffset: r - baseRow, externalWorkbooks: books)).cell
            }
        }.value
        host?.reportProgress(nil, label: nil)
        var s = doc.workbook.sheets[si]
        let col = s.columnCount
        s.appendColumn(header: query.headerRow ? name : nil, values: values, startRow: first)
        doc.workbook.sheets[si] = s
        autoWidthsFor = -1
        reloadSheet()
        grid.scrollTo(row: active.row, col: col)
        gridHeaderClicked(column: col, extend: false)
        let errors = values.filter { if case .error = $0 { return true }; return false }.count
        return .success(ComputedColumn(column: col, rows: values.count, errors: errors, sample: Array(values.prefix(5))))
    }
}
