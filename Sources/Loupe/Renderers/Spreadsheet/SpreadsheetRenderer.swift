import AppKit
import SwiftUI
import LoupeCore
import Quartz

/// Every table format (CSV/TSV, XLSX, ODS, and XLS/Numbers via Numbers) is converted into
/// Loupe's own Workbook and shown in one grid with filtering, sorting, hiding, selection
/// statistics, formulas, editing and zoom.
@MainActor
final class SpreadsheetRenderer: NSObject, Renderer, ObservableObject, GridViewOwner {
    static let engineName = "表格"
    static let directExtensions: Set<String> = ["csv", "tsv", "tab", "xlsx", "xlsm", "xltx", "ods"]
    static let convertExtensions: Set<String> = ["xls", "xlt", "et", "numbers"]

    static func canHandle(_ file: FileContext) -> Bool {
        guard !file.isDirectory, file.size < 300 << 20 else { return false }
        if file.format.family == .csv { return true }
        let t = file.format.token.lowercased()
        return directExtensions.contains(file.ext) || convertExtensions.contains(file.ext)
            || ["xlsx", "xls", "ods"].contains(t) || file.format.iwork == .numbers
    }

    // Published UI state
    @Published var sheetIndex = 0
    @Published var formulaText = ""
    @Published var resultText = ""
    @Published var resultIsError = false
    @Published var address = "A1"
    @Published var searchText = ""
    /// The calculator bar's formula (never written into the file).
    @Published var calcText = ""
    /// Other workbooks referenced as [文件.xlsx]: picked by the user, and loaded ones.
    var externalURLs: [String: URL] = [:]
    var externalCache: [String: Workbook] = [:]
    @Published var searchInfo = ""
    @Published var headerRow = true

    /// The workbook and its unsaved changes; the grid only shows and edits it.
    var doc = SpreadsheetDocument(workbook: Workbook(sheets: [], source: ""))
    var workbook: Workbook { doc.workbook }
    var resizeSnapshot: Snapshot?
    @Published var dirty = false
    var editor: CellEditor?
    /// The .xlsx we patch on save: the file itself, or Numbers' conversion of xls/numbers.
    var saveBase: URL?
    var queries: [SheetQuery] = []
    private(set) var visible: [Int] = []
    var rects: [GridRect] = []
    var active = GridPoint(row: 0, col: 0)
    var anchor = GridPoint(row: 0, col: 0)
    var matchKeys = Set<Int>()
    var matchList: [GridPoint] = []
    var matchCursor = -1
    var matchQuery = ""
    var computedCount = 0

    // Layout and drawing caches (see SpreadsheetPainter)
    var layout = GridLayout()
    @Published var zoom: CGFloat = 1
    var autoWidths: [Int: CGFloat] = [:]
    var autoWidthsFor = -1
    var fitHeights: [Int: CGFloat] = [:]
    var mergeTopLeft: [Int: MergeRange] = [:]
    var mergeCovered = Set<Int>()
    var mergeViews: [MergeView] = []
    var activeMerges: [Int: Int] = [:]
    var viewRowOf: [Int] = []
    var lookCache: [CellLookKey: CellLook] = [:]
    /// Charts, pictures and shapes over the cells (see SpreadsheetDrawings).
    let drawingPainter = DrawingPainter()

    let grid = GridView()
    let container = NSView()
    var popover: NSPopover?
    weak var host: RenderHost?
    var file: FileContext?
    var converted: String?

    required override init() { super.init() }

    var sheet: Sheet { workbook.sheets.indices.contains(sheetIndex) ? workbook.sheets[sheetIndex] : Sheet(name: "", rows: []) }
    var query: SheetQuery {
        get { queries.indices.contains(sheetIndex) ? queries[sheetIndex] : SheetQuery() }
        set { if queries.indices.contains(sheetIndex) { queries[sheetIndex] = newValue } }
    }

    // MARK: Loading

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        self.host = host
        buildView()
        // Loupe is a viewer first: formatted workbooks open as they look in Excel, and are only
        // parsed (or converted by Numbers) once the table tools are asked for. Text tables (CSV)
        // have no formatting, so they open in the table tools.
        if file.format.family != .csv && AppSettings.shared.spreadsheetOpensOriginal {
            let url = file.url
            let saved = await Task.detached(priority: .userInitiated) { SpreadsheetReader.savedZoom(xlsx: url) }.value
            originalSheetZoom = saved.map { CGFloat($0) / 100 } ?? 1
            viewMode = 1
            return container
        }
        try await loadWorkbook()
        return container
    }

    /// True once the file has been read into Loupe's own table.
    private(set) var workbookLoaded = false
    var workbookTask: Task<Void, Never>?
    private var originalSheetZoom: CGFloat = 1

    /// Reads (and for xls/Numbers, converts) the workbook into the table tools.
    private func loadWorkbook() async throws {
        guard let file, let host else { return }
        let url = file.url
        let ext = file.ext
        let token = file.format.token.lowercased()
        let delimiter = file.format.delimiter
        let isCSV = file.format.family == .csv
        let needsConversion = Self.convertExtensions.contains(ext) || file.format.iwork == .numbers || (token == "xls" && ext != "xlsx")

        var source = url
        if needsConversion {
            guard DocumentExporter.appURL(.numbers) != nil else {
                throw RenderError.unsupported("此格式需要 Numbers 转换后才能用表格工具打开")
            }
            host.reportProgress(nil, label: "正在通过 Numbers 转换表格…")
            do {
                source = try await DocumentExporter.export(url, with: .numbers, as: .xlsx)
                converted = "由 Numbers 转换"
                saveBase = source
            } catch ExportError.notAuthorized {
                host.showNotice("需要允许 Loupe 控制 Numbers 才能用表格工具打开此文件（系统设置 › 隐私与安全性 › 自动化）。", style: .warning,
                                action: NoticeAction(title: "打开设置") { DocumentExporter.openAutomationSettings() })
                throw RenderError.unsupported("没有「自动化」权限")
            }
        } else if file.size > 4 << 20 {
            host.reportProgress(nil, label: "正在读取表格…")
        }
        let isODS = ext == "ods" || token == "ods"
        if !needsConversion && !isCSV && !isODS { saveBase = url }
        var wb: Workbook = try await Task.detached(priority: .userInitiated) {
            if isCSV { return try SpreadsheetReader.readDelimited(url: source, delimiter: delimiter) }
            if isODS { return try SpreadsheetReader.readODS(url: source) }
            return try SpreadsheetReader.readXLSX(url: source)
        }.value
        try Task.checkCancellation()
        host.reportProgress(nil, label: nil)
        // An empty workbook is shown as the empty table it is.
        if wb.sheets.isEmpty { wb.sheets = [Sheet(name: "Sheet1", rows: [])] }
        doc = SpreadsheetDocument(workbook: wb)
        queries = wb.sheets.map { s in
            var q = SheetQuery()
            // A frozen pane's last row is the header (rows above it, like a title, stay pinned).
            if s.frozenRows >= 1 && s.frozenRows <= 12 && s.frozenRows < s.rows.count { q.headerRowIndex = s.frozenRows - 1 }
            else { q.headerRowIndex = Self.looksLikeHeader(s) ? 0 : nil }
            q.hiddenRows = s.hiddenRows
            q.hiddenColumns = s.hiddenColumns
            return q
        }
        sheetIndex = wb.sheets.firstIndex { !$0.rows.isEmpty } ?? 0
        workbookLoaded = true
        originalSheetZoom = CGFloat(wb.sheets.first?.zoomScale ?? 100) / 100
        reloadSheet(resetSelection: true)
        adoptSavedZoom()
    }

    /// Switching to the table tools the first time reads the workbook in the background.
    func loadWorkbookForTools() {
        guard !workbookLoaded, workbookTask == nil else { return }
        workbookTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadWorkbook()
                if self.viewMode == 0 { self.container.window?.makeFirstResponder(self.grid) }
            } catch {
                self.host?.reportProgress(nil, label: nil)
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.host?.showNotice("无法用表格工具打开：\(msg)", style: .warning, action: nil)
                self.viewMode = 1
            }
            self.workbookTask = nil
            self.host?.rendererDidUpdate()
        }
    }


    /// A first row of all-text cells above a row containing numbers reads as a header.
    static func looksLikeHeader(_ s: Sheet) -> Bool {
        guard s.rows.count > 1 else { return false }
        let first = s.rows[0]
        guard !first.isEmpty, first.allSatisfy({ if case .text = $0 { return true }; return $0.isEmpty }) else { return false }
        let probe = s.rows.dropFirst().prefix(20)
        return probe.contains { row in row.contains { if case .number = $0 { return true }; if case .date = $0 { return true }; return false } }
            || Set(first.map(\.display)).count == first.count
    }

    private func buildView() {
        grid.owner = self
        let bar = RendererHostingView(FormulaBar(r: self))
        bar.sizingOptions = [.intrinsicContentSize]
        let tabs = RendererHostingView(SheetTabs(r: self))
        tabs.sizingOptions = [.intrinsicContentSize]
        for v in [bar, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        for v in [grid, tabs] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            grid.topAnchor.constraint(equalTo: body.topAnchor),
            grid.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: grid.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }

    // MARK: Original view

    /// 0 = Loupe's table tools, 1 = the original file through Quick Look (full fidelity, read-only).
    @Published var viewMode = 0 { didSet { if viewMode != oldValue { applyViewMode() } } }
    private let body = NSView()
    private var original: OriginalPreview?
    var originalView: NSView? { original }
    /// Zoom of the original preview relative to the file's own saved zoom (pinches included).
    var originalZoom: CGFloat {
        get { original?.zoom ?? 1 }
        set { objectWillChange.send(); original?.zoom = newValue }
    }

    private func applyViewMode() {
        if viewMode == 1 {
            endEditing(commit: true)
            // Quick Look shows the sheet the workbook opens on, at the zoom Excel saved.
            if original == nil, let url = file?.url, let o = OriginalPreview(url: url, sheetZoom: originalSheetZoom) {
                o.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(o)
                NSLayoutConstraint.activate([
                    o.topAnchor.constraint(equalTo: body.topAnchor), o.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                    o.leadingAnchor.constraint(equalTo: body.leadingAnchor), o.trailingAnchor.constraint(equalTo: body.trailingAnchor)
                ])
                original = o
            }
            original?.isHidden = false
            body.isHidden = true
            container.window?.makeFirstResponder(original?.focusView)
        } else {
            original?.isHidden = true
            body.isHidden = false
            container.window?.makeFirstResponder(grid)
            loadWorkbookForTools()
        }
        host?.rendererDidUpdate()
    }

    // MARK: Sheet / query

    func reloadSheet(resetSelection: Bool = false) {
        headerRow = query.headerRow
        visible = query.visibleRows(in: sheet)
        rebuildMerges()
        if autoWidthsFor != sheetIndex { rebuildAutoWidths(); autoWidthsFor = sheetIndex }
        rebuildFitHeights()
        lookCache = [:]
        // Cell values may have changed: charts read them again.
        drawingPainter.reset()
        rebuildLayout()
        if resetSelection || active.row >= visible.count || active.col >= sheet.columnCount {
            let start = GridPoint(row: 0, col: layout.cols.first ?? 0)
            rects = [GridRect(start, start)]
            active = start
            anchor = start
        }
        recomputeMatches()
        grid.reload()
        selectionChanged()
    }

    /// Shows a sheet at the zoom it was saved at in Excel.
    func adoptSavedZoom() {
        let z = CGFloat(sheet.zoomScale / 100)
        if abs(z - zoom) > 0.001 { setZoom(z) }
    }

    /// Re-measures after sizes changed but rows did not (resize, zoom).
    func relayout() {
        rebuildLayout()
        grid.reload()
    }

    func switchSheet(_ i: Int) {
        guard workbook.sheets.indices.contains(i), i != sheetIndex else { return }
        endEditing(commit: true)
        sheetIndex = i
        reloadSheet(resetSelection: true)
        adoptSavedZoom()
        grid.scrollOrigin(to: .zero)
    }

    func setHeaderRow(_ on: Bool) {
        var q = query
        q.headerRowIndex = on ? (sheet.frozenRows >= 1 && sheet.frozenRows <= 12 ? sheet.frozenRows - 1 : 0) : nil
        query = q
        reloadSheet(resetSelection: true)
    }

    func sort(column c: Int, ascending: Bool?) {
        var q = query
        if let ascending { q.sortColumn = c; q.ascending = ascending } else { q.sortColumn = nil }
        query = q
        reloadSheet()
    }

    func setFilter(_ rule: FilterRule?, column c: Int) {
        var q = query
        q.filters[c] = rule
        query = q
        reloadSheet(resetSelection: true)
    }

    func clearFilters() {
        var q = query
        q.filters = [:]
        q.sortColumn = nil
        query = q
        reloadSheet(resetSelection: true)
    }

    func hideSelectedRows() {
        var q = query
        for rect in rects { for r in rect.r0...rect.r1 where r < visible.count { q.hiddenRows.insert(visible[r]) } }
        query = q
        reloadSheet(resetSelection: true)
    }

    func hideColumns(_ cols: [Int]) {
        var q = query
        q.hiddenColumns.formUnion(cols)
        query = q
        reloadSheet()
    }

    func unhideAll() {
        var q = query
        q.hiddenRows = []
        q.hiddenColumns = []
        query = q
        reloadSheet()
    }

    var hiddenCount: (rows: Int, cols: Int) { (query.hiddenRows.count, query.hiddenColumns.count) }
    var isFiltered: Bool { !query.filters.isEmpty || query.sortColumn != nil }

    static func color(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    var isDark: Bool { grid.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    static func isNeutralLight(_ c: RGBA) -> Bool {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        return luminance(c) > 0.8 && Int(mx) - Int(mn) < 24
    }

    static func luminance(_ c: RGBA) -> Double {
        (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
    }

    // MARK: GridViewOwner

    var gridLayout: GridLayout { layout }
    var gridGutterDigits: Int { String(max(1, sheet.rows.count)).count }

    func gridSelection() -> (rects: [GridRect], active: GridPoint, anchor: GridPoint) { (rects, active, anchor) }

    func gridSelect(_ r: [GridRect], active a: GridPoint, anchor an: GridPoint) {
        // Like Excel, a selection always covers merged areas whole: clicking (or dragging a
        // little) inside one selects the entire area, and the active cell is its top-left.
        let r = r.map(expandedToMerges)
        let a = mergeArea(row: a.row, col: a.col)?.topLeft ?? a
        let an = mergeArea(row: an.row, col: an.col)?.topLeft ?? an
        // Redraw what the old and the new selection cover.
        var dirtyRect = NSRect.null
        for g in rects + r { if let rr = layout.rect(g) { dirtyRect = dirtyRect.union(rr) } }
        for p in [active, a] { if let rr = cellArea(row: p.row, col: p.col) { dirtyRect = dirtyRect.union(rr) } }
        rects = r
        active = a
        anchor = an
        if !dirtyRect.isNull { grid.invalidate(dirtyRect) }
        selectionChanged()
    }

    func gridVisibleColumns() -> [Int] { layout.cols }

    func gridColumnHeader(_ c: Int) -> (mark: String, selected: Bool) {
        let q = query
        var mark = ""
        if q.sortColumn == c { mark = q.ascending ? "↑" : "↓" }
        if q.filters[c] != nil { mark += "⏷" }
        return (mark, rects.contains { $0.c0 <= c && c <= $0.c1 })
    }

    func gridRowLabel(_ row: Int) -> (text: String, selected: Bool, pinned: Bool) {
        guard row < visible.count else { return ("", false, false) }
        let sr = visible[row]
        return ("\(sr + 1)", rects.contains { $0.r0 <= row && row <= $0.r1 }, query.pinnedRows.contains(sr))
    }

    func gridHeaderClicked(column c: Int, extend: Bool) {
        guard !visible.isEmpty else { return }
        let start = extend ? anchor.col : c
        let a = GridPoint(row: 0, col: start), b = GridPoint(row: visible.count - 1, col: c)
        gridSelect([GridRect(a, b)], active: GridPoint(row: 0, col: c), anchor: GridPoint(row: 0, col: start))
    }

    func gridHeaderPanel(column c: Int, rect: NSRect, in view: NSView) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        let host = NSHostingController(rootView: ColumnPanel(r: self, column: c, close: { [weak p] in p?.close() }))
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover = p
    }

    func openColumnPanel(_ c: Int) {
        guard let i = layout.position(of: c) else { return }
        grid.scrollTo(row: max(0, min(active.row, visible.count - 1)), col: c)
        let x = layout.xs[i] - grid.scrollOffset.x
        gridHeaderPanel(column: c, rect: NSRect(x: x, y: 0, width: layout.xs[i + 1] - layout.xs[i], height: GridView.headerHeight), in: grid.header)
    }

    // MARK: Selection → formula bar & statistics

    private(set) var stats = SelectionStats([])

    private func selectionChanged() {
        address = Sheet.columnName(max(0, active.col)) + (active.row < visible.count ? "\(visible[active.row] + 1)" : "")
        if active.row < visible.count {
            let sr = visible[active.row]
            formulaText = sheet.formulas[Sheet.key(sr, active.col)] ?? sheet.cell(sr, active.col).display
        } else {
            formulaText = ""
        }
        resultText = ""
        var values: [CellValue] = []
        var budget = 2_000_000
        let hiddenCols = query.hiddenColumns
        // A selected merged area counts as the one cell it shows.
        let counted = rects.count == 1 && mergeArea(row: active.row, col: active.col)?.area == rects[0] ? [GridRect(active, active)] : rects
        outer: for rect in counted {
            for r in rect.r0...max(rect.r0, min(rect.r1, visible.count - 1)) where r < visible.count {
                for c in rect.c0...rect.c1 where !hiddenCols.contains(c) {
                    values.append(sheet.cell(visible[r], c))
                    budget -= 1
                    if budget == 0 { break outer }
                }
            }
        }
        stats = SelectionStats(values)
        host?.rendererDidUpdate()
    }

    func fmt(_ d: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(d) >= 1000 ? 2 : 4
        return f.string(from: NSNumber(value: d)) ?? CellValue.format(d)
    }

    func copyStats() {
        var parts = ["计数 \(stats.nonEmpty)"]
        if stats.numeric > 0 {
            parts += ["求和 \(fmt(stats.sum))", "平均 \(fmt(stats.average ?? 0))", "最小 \(fmt(stats.min ?? 0))", "最大 \(fmt(stats.max ?? 0))"]
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "  "), forType: .string)
    }

    // MARK: Renderer

    func cleanup() {
        workbookTask?.cancel()
        grid.window?.undoManager?.removeAllActions(withTarget: self)
        editor?.removeFromSuperview()
        editor = nil
        host?.window?.isDocumentEdited = false
        popover?.close()
        original?.close()
        original = nil
        grid.owner = nil
        doc = SpreadsheetDocument(workbook: Workbook(sheets: [], source: ""))
    }

    var hasUnsavedChanges: Bool { dirty }
    func saveChanges(completion: @escaping (Bool) -> Void) { save(completion: completion) }

    var presentation: StagePresentation { .sheet }
    var wantsArrowKeys: Bool { true }
    var initialFirstResponder: NSView? { viewMode == 1 ? original?.focusView : grid }
    var controls: AnyView? { AnyView(SheetStripControls(r: self)) }
    var controlsPlacement: ControlsPlacement { .strip }

    func supports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .find, .findNext, .findPrevious, .copy, .toggleSource: return true
        case .saveAs, .exportCSV, .exportXLSX: return workbookLoaded
        case .zoomIn, .zoomOut, .actualSize: return true
        case .save: return dirty
        default: return false
        }
    }

    func perform(_ c: ViewerCommand) {
        switch c {
        case .toggleSource: viewMode = viewMode == 0 ? 1 : 0
        case .save: save()
        case .saveAs: saveAs()
        case .exportCSV: export(asCSV: true)
        case .exportXLSX: export(asCSV: false)
        case .find: viewMode = 0; focusSearch = true
        case .findNext: if matchList.isEmpty { runSearch() } else { findNext(1) }
        case .findPrevious: findNext(-1)
        case .zoomIn: stepZoom(1)
        case .zoomOut: stepZoom(-1)
        case .actualSize: if viewMode == 1 { originalZoom = 1; host?.rendererDidUpdate() } else { setZoom(sheet.zoomScale / 100) }
        default: break
        }
    }

    @Published var focusSearch = false

    var statusText: String {
        if viewMode == 1 {
            return "原样（只读）" + (abs(originalZoom - 1) > 0.001 ? " · 缩放 \(Int((originalZoom * 100).rounded()))%" : "") + (dirty ? " · ● 已修改（⌘S 保存）" : "")
        }
        guard workbookLoaded else { return workbookTask != nil ? "正在读取表格…" : "" }
        let total = max(0, sheet.rows.count - query.firstDataRow)
        let shownData = visible.count - query.pinnedRows.filter { !query.hiddenRows.contains($0) }.count
        var parts: [String] = []
        parts.append(shownData == total ? "\(Fmt.number(total)) 行 × \(sheet.columnCount) 列" : "显示 \(Fmt.number(shownData)) / \(Fmt.number(total)) 行")
        if abs(zoom - 1) > 0.001 { parts.append("缩放 \(Int((zoom * 100).rounded()))%") }
        if dirty { parts.append("● 已修改（⌘S 保存）") }
        if stats.cells > 1 {
            parts.append("已选 \(Fmt.number(stats.cells)) 格")
            if stats.numeric > 0 {
                parts.append("求和 \(fmt(stats.sum))")
                parts.append("平均 \(fmt(stats.average ?? 0))")
                parts.append("计数 \(Fmt.number(stats.numeric))")
                parts.append("最小 \(fmt(stats.min ?? 0)) · 最大 \(fmt(stats.max ?? 0))")
            } else {
                parts.append("非空 \(Fmt.number(stats.nonEmpty))")
            }
        }
        return parts.joined(separator: " · ")
    }

    var infoSections: [InfoSection] {
        guard workbookLoaded else {
            return [InfoSection("表格", [InfoItem("显示方式", "原样（系统快速查看）"),
                                         InfoItem("说明", "切换到「表格工具」后读取工作表，可筛选、计算和编辑")])]
        }
        var items = [InfoItem("来源", workbook.source + (converted.map { " · \($0)" } ?? "")),
                     InfoItem("工作表", workbook.sheets.map(\.name).joined(separator: "、")),
                     InfoItem("当前表", "\(sheet.name) · \(Fmt.number(sheet.rows.count)) 行 × \(sheet.columnCount) 列")]
        if !sheet.formulas.isEmpty { items.append(InfoItem("公式单元格", Fmt.number(sheet.formulas.count))) }
        if !sheet.merges.isEmpty { items.append(InfoItem("合并单元格", Fmt.number(sheet.merges.count))) }
        items.append(InfoItem("说明", "筛选、排序、隐藏只影响显示；编辑后 ⌘S 才会写回原文件"))
        return [InfoSection("表格", items)]
    }
}

/// Bridges closures to NSMenuItem target/action.
final class MenuAction: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

extension FValue {
    var isErrorValue: Bool { if case .error = self { return true }; return false }
}
