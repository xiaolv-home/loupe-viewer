import AppKit
import SwiftUI
import PDFKit
import LoupeCore
import LoupeObjC
import Quartz

@MainActor
final class PDFRenderer: NSObject, Renderer, ObservableObject, PDFViewDelegate, NSSearchFieldDelegate {
    static let engineName = "PDFKit"
    static func canHandle(_ file: FileContext) -> Bool { true }

    @Published var pageIndex = 0
    @Published var pageCount = 0
    @Published var zoomPercent = 100
    @Published var sidebarVisible = false
    @Published var sidebarTab = 0 { didSet { updateSidebarTab() } }
    @Published var searchStatus = ""
    @Published var locked = false

    let pdfView = SafePDFView()
    private var document: PDFDocument?
    private let root = NSView()
    private let sidebar = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    /// Created the first time the thumbnail sidebar is shown (most PDFs are read without it).
    private var thumbs: PDFThumbnailView?
    private weak var sidebarHeader: NSView?
    private let outlineList = OutlineList()
    private var searchBar: NSView!
    private var searchBarHeight: NSLayoutConstraint!
    private let searchField = NSSearchField()
    private var matches: [PDFSelection] = []
    private var matchIndex = -1
    private var observers: [NSObjectProtocol] = []
    private weak var host: RenderHost?
    private var lockHost: NSView?
    /// Title shown in the info panel when this PDF was generated from another document.
    var derivedFrom: String?

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        let url = file.url
        guard let doc = await Task.detached(priority: .userInitiated, operation: { PDFDocument(url: url) }).value,
              doc.pageCount > 0 || doc.isLocked else {
            throw RenderError.unreadable("PDF 无法解析（文件可能已损坏）")
        }
        try Task.checkCancellation()
        return makeView(document: doc, host: host)
    }

    func makeView(document doc: PDFDocument, host: RenderHost) -> NSView {
        self.host = host
        document = doc
        pageCount = doc.pageCount

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        pdfView.backgroundColor = Theme.stage
        pdfView.pageShadowsEnabled = true
        pdfView.delegate = self
        pdfView.interpolationQuality = .high
        pdfView.document = doc

        outlineList.root = doc.outlineRoot
        outlineList.onSelect = { [weak self] o in
            if let d = o.destination { self?.pdfView.go(to: d) }
            else if let a = o.action as? PDFActionGoTo { self?.pdfView.go(to: a.destination) }
        }

        buildLayout()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncState() }
        })
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncState() }
        })
        if doc.isLocked { showUnlock() }
        pdfView.pendingInitialPage = true
        syncState()
        return root
    }

    private func buildLayout() {
        // Sidebar: segmented header + thumbnails / outline.
        let seg = RendererHostingView(PDFSidebarHeader(r: self))
        seg.sizingOptions = [.intrinsicContentSize]
        sidebarHeader = seg
        for v in [seg, outlineList] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .withinWindow
        effect.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(effect, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), effect.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            effect.topAnchor.constraint(equalTo: sidebar.topAnchor), effect.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            seg.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            seg.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            outlineList.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 8),
            outlineList.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            outlineList.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            outlineList.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: sidebar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])
        sidebar.isHidden = true
        updateSidebarTab()

        // Search bar.
        searchField.placeholderString = "在文档中搜索"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.sendsWholeSearchString = true
        let status = RendererHostingView(PDFSearchStatus(r: self))
        status.sizingOptions = [.intrinsicContentSize]
        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "上一个")!, target: self, action: #selector(prevMatch))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "下一个")!, target: self, action: #selector(nextMatch))
        let done = NSButton(title: "完成", target: self, action: #selector(hideSearch))
        for b in [prev, next, done] { b.bezelStyle = .accessoryBarAction; b.controlSize = .small }
        let stack = NSStackView(views: [searchField, status, prev, next, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        searchBar = bar
        bar.isHidden = true

        for v in [sidebar, bar, pdfView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        searchBarHeight = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,
            bar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            searchBarHeight,
            pdfView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func updateSidebarTab() {
        if sidebarVisible && sidebarTab == 0 { ensureThumbs() }
        thumbs?.isHidden = sidebarTab != 0
        outlineList.isHidden = sidebarTab != 1
    }

    private func ensureThumbs() {
        guard thumbs == nil, let seg = sidebarHeader else { return }
        let t = PDFThumbnailView()
        t.pdfView = pdfView
        t.thumbnailSize = NSSize(width: 120, height: 150)
        t.backgroundColor = .clear
        t.maximumNumberOfColumns = 1
        t.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(t)
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 8),
            t.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            t.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            t.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        thumbs = t
    }

    var hasOutline: Bool { (document?.outlineRoot?.numberOfChildren ?? 0) > 0 }

    func toggleSidebar() {
        sidebarVisible.toggle()
        sidebar.isHidden = !sidebarVisible
        updateSidebarTab()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            sidebarWidth.animator().constant = sidebarVisible ? 176 : 0
        }
    }

    private func syncState() {
        guard let doc = document, let page = pdfView.currentPage else { return }
        pageIndex = doc.index(for: page)
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
        host?.rendererDidUpdate()
    }

    func go(toPage i: Int) {
        guard let doc = document, i >= 0, i < doc.pageCount, let p = doc.page(at: i) else { return }
        pdfView.go(to: p)
    }

    // MARK: Unlock

    private func showUnlock() {
        locked = true
        let v = RendererHostingView(PDFUnlockView(r: self))
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.topAnchor.constraint(equalTo: root.topAnchor), v.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        lockHost = v
    }

    func unlock(_ password: String) -> Bool {
        guard let doc = document, doc.unlock(withPassword: password) else { return false }
        locked = false
        lockHost?.removeFromSuperview()
        lockHost = nil
        pdfView.document = nil
        pdfView.document = doc
        pageCount = doc.pageCount
        outlineList.root = doc.outlineRoot
        syncState()
        return true
    }

    // MARK: Search

    func showSearch() {
        searchBar.isHidden = false
        searchBarHeight.constant = 40
        root.window?.makeFirstResponder(searchField)
    }

    @objc func hideSearch() {
        document?.cancelFindString()
        searchBar.isHidden = true
        searchBarHeight.constant = 0
        matches = []
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        searchStatus = ""
        root.window?.makeFirstResponder(pdfView)
    }

    @objc private func searchSubmitted() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let doc = document else { return }
        if !matches.isEmpty, q == lastQuery { nextMatch(); return }
        lastQuery = q
        doc.cancelFindString()
        matches = []
        matchIndex = -1
        pdfView.highlightedSelections = nil
        guard !q.isEmpty else { searchStatus = ""; return }
        searchStatus = "搜索中…"
        // findString(withOptions:) is synchronous but fast; run off-main to keep the UI fluid.
        let docRef = doc
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> [PDFSelection] in
                docRef.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
            }.value
            guard let self, self.lastQuery == q else { return }
            for s in found { s.color = Theme.emberNS.withAlphaComponent(0.45) }
            self.matches = found
            self.pdfView.highlightedSelections = found
            self.searchStatus = found.isEmpty ? "无结果" : "\(found.count) 处"
            if !found.isEmpty { self.nextMatch() }
        }
    }
    private var lastQuery = ""

    @objc func nextMatch() { stepMatch(1) }
    @objc func prevMatch() { stepMatch(-1) }

    private func stepMatch(_ d: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + d + matches.count) % matches.count
        let s = matches[matchIndex]
        pdfView.setCurrentSelection(s, animate: true)
        pdfView.go(to: s)
        searchStatus = "\(matchIndex + 1) / \(matches.count)"
    }

    // MARK: Links

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        // External links are never opened automatically; offer it as an explicit action.
        MainActor.assumeIsolated {
            host?.showNotice("已阻止自动打开链接：\(url.absoluteString)", style: .info,
                             action: NoticeAction(title: "在浏览器中打开") { NSWorkspace.shared.open(url) })
        }
    }

    // MARK: Slideshow

    func startSlideshow() {
        guard let doc = document else { return }
        SlideshowController.present(document: doc, startAt: pageIndex, from: root.window)
    }

    // MARK: Renderer

    func cleanup() {
        document?.cancelFindString()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        // PDFKit's thumbnail view keeps internal timers that hold it alive; detach it fully.
        thumbs?.pdfView = nil
        thumbs?.removeFromSuperview()
        thumbs = nil
        outlineList.root = nil
        pdfView.delegate = nil
        pdfView.document = nil
        // Also used inside the iWork renderer, so take its own panels apart here.
        root.dismantleTree()
        root.removeFromSuperview()
        document = nil
    }

    var presentation: StagePresentation { .bleed }
    var controlsPlacement: ControlsPlacement { .floating }
    var controls: AnyView? { locked ? nil : AnyView(PDFControls(r: self)) }
    var initialFirstResponder: NSView? { pdfView }

    func supports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .zoomIn, .zoomOut, .actualSize, .zoomToFit, .find, .findNext, .findPrevious, .slideshow: return !locked
        default: return false
        }
    }

    func perform(_ c: ViewerCommand) {
        switch c {
        case .zoomIn: pdfView.autoScales = false; pdfView.zoomIn(nil)
        case .zoomOut: pdfView.autoScales = false; pdfView.zoomOut(nil)
        case .actualSize: pdfView.autoScales = false; pdfView.scaleFactor = 1
        case .zoomToFit: pdfView.autoScales = true
        case .find: showSearch()
        case .findNext: nextMatch()
        case .findPrevious: prevMatch()
        case .slideshow: startSlideshow()
        default: break
        }
        syncState()
    }

    var statusText: String {
        guard pageCount > 0 else { return locked ? "已加密" : "" }
        return "第 \(pageIndex + 1) / \(pageCount) 页 · \(zoomPercent)%"
    }

    var infoSections: [InfoSection] {
        guard let doc = document else { return [] }
        var items = [InfoItem("页数", "\(doc.pageCount)")]
        let a = doc.documentAttributes ?? [:]
        func s(_ k: PDFDocumentAttribute) -> String? { (a[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let t = s(.titleAttribute) { items.append(InfoItem("标题", t)) }
        if let t = s(.authorAttribute) { items.append(InfoItem("作者", t)) }
        if let t = s(.subjectAttribute) { items.append(InfoItem("主题", t)) }
        if let t = s(.creatorAttribute) { items.append(InfoItem("创建程序", t)) }
        if let t = s(.producerAttribute) { items.append(InfoItem("生成程序", t)) }
        if let d = a[PDFDocumentAttribute.creationDateAttribute] as? Date { items.append(InfoItem("创建于", Fmt.date(d))) }
        if let d = a[PDFDocumentAttribute.modificationDateAttribute] as? Date { items.append(InfoItem("修改于", Fmt.date(d))) }
        items.append(InfoItem("PDF 版本", "\(doc.majorVersion).\(doc.minorVersion)"))
        if let p = doc.page(at: 0) {
            let b = p.bounds(for: .mediaBox)
            items.append(InfoItem("页面尺寸", String(format: "%.0f × %.0f pt（%.0f × %.0f mm）", b.width, b.height, b.width / 72 * 25.4, b.height / 72 * 25.4)))
        }
        items.append(InfoItem("加密", doc.isEncrypted ? "是" : "否"))
        items.append(InfoItem("目录", hasOutline ? "有" : "无"))
        if let d = derivedFrom { items.append(InfoItem("来源", d)) }
        return [InfoSection("PDF", items)]
    }
}

private struct PDFSidebarHeader: View {
    @ObservedObject var r: PDFRenderer
    var body: some View {
        LensSegment(options: ["缩略图", "目录"], selection: $r.sidebarTab)
    }
}

private struct PDFSearchStatus: View {
    @ObservedObject var r: PDFRenderer
    var body: some View {
        Text(r.searchStatus).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
    }
}

private struct PDFControls: View {
    @ObservedObject var r: PDFRenderer
    @State private var pageText = ""
    var body: some View {
        HStack(spacing: 2) {
            LensButton(symbol: "sidebar.left", help: "缩略图与目录", active: r.sidebarVisible) { r.toggleSidebar() }
            LensDivider()
            LensButton(symbol: "chevron.up", help: "上一页", enabled: r.pageIndex > 0) { r.go(toPage: r.pageIndex - 1) }
            HStack(spacing: 3) {
                TextField("", text: $pageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 34)
                    .onSubmit { if let n = Int(pageText) { r.go(toPage: n - 1) }; pageText = "\(r.pageIndex + 1)" }
                Text("/ \(r.pageCount)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .help("输入页码后回车跳转")
            LensButton(symbol: "chevron.down", help: "下一页", enabled: r.pageIndex < r.pageCount - 1) { r.go(toPage: r.pageIndex + 1) }
            LensDivider()
            LensButton(symbol: "minus", help: "缩小（⌘−）") { r.perform(.zoomOut) }
            Readout(text: "\(r.zoomPercent)%", minWidth: 42)
            LensButton(symbol: "plus", help: "放大（⌘+）") { r.perform(.zoomIn) }
            LensButton(symbol: "arrow.left.and.right", help: "适应宽度（⌘9）", active: r.pdfView.autoScales) { r.perform(.zoomToFit) }
            LensDivider()
            LensButton(symbol: "magnifyingglass", help: "搜索（⌘F）") { r.showSearch() }
            LensButton(symbol: "play.rectangle", help: "全屏放映（⌥⌘P）") { r.startSlideshow() }
        }
        .onAppear { pageText = "\(r.pageIndex + 1)" }
        .onChange(of: r.pageIndex) { _, v in pageText = "\(v + 1)" }
    }
}

private struct PDFUnlockView: View {
    @ObservedObject var r: PDFRenderer
    @State private var pw = ""
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.ember)
                Text("此 PDF 已加密").font(.system(size: 15, weight: .semibold))
            }
            Text("输入文档密码以查看内容。密码只用于本次解锁，不会被保存。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                SecureField("密码", text: $pw).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { failed = !r.unlock(pw) }
                Button("解锁") { failed = !r.unlock(pw) }.keyboardShortcut(.defaultAction)
            }
            if failed { Text("密码不正确").font(.system(size: 11)).foregroundStyle(Theme.ember) }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.sheet)))
        .overlay(CropMarks(gap: 6, length: 12).stroke(Color.primary.opacity(0.3), lineWidth: 0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.stage))
    }
}
