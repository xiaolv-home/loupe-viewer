import AppKit
import SwiftUI
import LoupeCore

extension NSToolbarItem.Identifier {
    static let loupeTitle = NSToolbarItem.Identifier("loupe.title")
    static let loupeNav = NSToolbarItem.Identifier("loupe.nav")
    static let loupeShare = NSToolbarItem.Identifier("loupe.share")
    static let loupeMore = NSToolbarItem.Identifier("loupe.more")
    static let loupeInfo = NSToolbarItem.Identifier("loupe.info")
    static let loupeAI = NSToolbarItem.Identifier("loupe.ai")
}

@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    /// The open documents (tabs); `model` is the one showing.
    let tabs: TabList
    var model: ViewerModel { tabs.current }
    var stage: StageViewController { stages[ObjectIdentifier(model)]! }
    /// The sidebar's folder, shared by all tabs (never rebuilt when switching).
    let browser = FolderBrowser()
    private var stages: [ObjectIdentifier: StageViewController] = [:]
    private let stageHost = NSViewController()
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var aiItem: NSSplitViewItem!
    /// The AI conversation in this window (it works on whichever tab is showing).
    let ai = AISession()
    var onClose: ((ViewerWindowController) -> Void)?

    init(autosave: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 380)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // Tabs are Loupe's own (TabStrip): switching only swaps the content view.
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = Theme.stage
        let first = ViewerModel()
        tabs = TabList(first: first)
        super.init(window: window)
        stageHost.view = NSView()
        ai.window = self
        adopt(first)
        show(first)

        let sidebarVC = NSHostingController(rootView: SidebarView(tabs: tabs, browser: browser))
        sidebarVC.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !AppSettings.shared.showSidebar

        let stageItem = NSSplitViewItem(viewController: stageHost)
        stageItem.minimumThickness = 360

        let inspectorVC = NSHostingController(rootView: CurrentInspector(tabs: tabs))
        inspectorVC.sizingOptions = []
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 250
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true

        let aiVC = NSHostingController(rootView: AIPanel(session: ai, tabs: tabs))
        aiVC.sizingOptions = []
        aiItem = NSSplitViewItem(inspectorWithViewController: aiVC)
        aiItem.minimumThickness = 320
        aiItem.maximumThickness = 640
        aiItem.preferredThicknessFraction = 0.32
        aiItem.canCollapse = true
        aiItem.isCollapsed = AppEnvironment.isScripted || !UserDefaults.standard.bool(forKey: "aiPanelOpen")

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(stageItem)
        split.addSplitViewItem(inspectorItem)
        split.addSplitViewItem(aiItem)
        if !AppEnvironment.isScripted { split.splitView.autosaveName = "LoupeSplit" }
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1080, height: 720))

        let toolbar = NSToolbar(identifier: "LoupeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self

        if autosave && !AppEnvironment.isScripted {
            windowFrameAutosaveName = "LoupeMainWindow"
            if !window.setFrameUsingName("LoupeMainWindow") { window.center() }
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(_ url: URL) {
        model.open(url)
        showWindow(nil)
    }

    // MARK: Tabs

    private func adopt(_ m: ViewerModel, home: Bool = true) {
        m.windowController = self
        m.browser = browser
        let s = StageViewController(model: m, startsOnHome: home)
        m.stage = s
        stages[ObjectIdentifier(m)] = s
        stageHost.addChild(s)
    }

    /// Puts a document's content in the window; the others stay alive (state kept) but detached.
    private func show(_ m: ViewerModel) {
        guard let s = stages[ObjectIdentifier(m)] else { return }
        for v in stageHost.view.subviews where v !== s.view { v.removeFromSuperview() }
        if s.view.superview !== stageHost.view {
            s.view.frame = stageHost.view.bounds
            s.view.autoresizingMask = [.width, .height]
            stageHost.view.addSubview(s.view)
        }
        tabs.select(m)
        window?.title = m.file?.name ?? "Loupe"
        window?.representedURL = m.file?.url
        window?.isDocumentEdited = m.renderer?.hasUnsavedChanges == true
        if let fr = m.renderer?.initialFirstResponder { window?.makeFirstResponder(fr) }
        m.rendererDidUpdate()
    }

    func select(_ m: ViewerModel) {
        guard m !== model, tabs.docs.contains(where: { $0 === m }) else { return }
        show(m)
    }

    /// A new tab beside the current one: empty (home page) or opening `url`.
    @discardableResult
    func addTab(_ url: URL?) -> ViewerModel {
        let m = ViewerModel()
        adopt(m, home: url == nil)
        tabs.insert(m, after: model)
        show(m)
        if let url { m.open(url) }
        return m
    }

    /// Closes a tab (asking first if it has unsaved edits). Closing the last one leaves the
    /// window on its home page.
    func closeTab(_ m: ViewerModel) {
        guard tabs.docs.contains(where: { $0 === m }) else { return }
        if m.renderer?.hasUnsavedChanges == true {
            if m !== model { show(m) }
            m.confirmLeaving { [weak self] ok in if ok { self?.finishClosing(m) } }
            return
        }
        finishClosing(m)
    }

    private func finishClosing(_ m: ViewerModel) {
        if tabs.docs.count == 1 {
            // The last tab: back to the home page rather than an empty window.
            m.close()
            stages[ObjectIdentifier(m)]?.showEmpty()
            show(m)
            return
        }
        let next = tabs.neighbour(of: m)
        m.close()
        if let s = stages.removeValue(forKey: ObjectIdentifier(m)) {
            s.view.removeFromSuperview()
            s.removeFromParent()
        }
        tabs.remove(m)
        if let next { show(next) }
    }

    func document(for url: URL) -> ViewerModel? {
        tabs.docs.first { $0.file?.url == url.standardizedFileURL }
    }

    var allDocuments: [ViewerModel] { tabs.docs }
    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }

    /// ⌘T and the + in the tab strip: a new tab on the home page.
    @objc override func newWindowForTab(_ sender: Any?) { addTab(nil) }
    /// ⌘W: closes the tab; on an empty home page it closes the window.
    @objc func closeTabAction(_ sender: Any?) {
        if tabs.docs.count == 1 && model.file == nil { window?.performClose(sender) } else { closeTab(model) }
    }
    @objc func nextTab(_ sender: Any?) { cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(-1) }
    func cycleTab(_ d: Int) {
        guard tabs.docs.count > 1, let i = tabs.docs.firstIndex(where: { $0 === model }) else { return }
        show(tabs.docs[(i + d + tabs.docs.count) % tabs.docs.count])
    }

    // MARK: Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Ask about each tab with unsaved edits, one at a time.
        guard let dirty = tabs.docs.first(where: { $0.renderer?.hasUnsavedChanges == true }) else { return true }
        show(dirty)
        dirty.confirmLeaving { [weak self] ok in
            guard ok else { return }
            dirty.close()
            self?.window?.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        ai.stop()
        for d in tabs.docs { d.close() }
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) { updateStripWidth() }

    func updateStripWidth() {
        guard let w = window else { return }
        let sidebar = sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width
        tabs.availableWidth = max(200, w.frame.width - sidebar - 300)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .loupeTitle, .flexibleSpace, .loupeNav, .loupeShare, .loupeMore, .inspectorTrackingSeparator, .loupeInfo, .loupeAI]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .loupeTitle:
            let item = NSToolbarItem(itemIdentifier: id)
            let host = NSHostingView(rootView: TabStrip(tabs: tabs,
                                                        select: { [weak self] m in self?.select(m) },
                                                        close: { [weak self] m in self?.closeTab(m) },
                                                        newTab: { [weak self] in self?.addTab(nil) }))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.visibilityPriority = .high
            item.label = "标签页"
            return item
        case .loupeNav:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "上一个")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "下一个")!
            ], selectionMode: .momentary, labels: ["上一个", "下一个"], target: self, action: #selector(navGroup(_:)))
            group.label = "浏览"
            group.subitems[0].toolTip = "上一个文件（←）"
            group.subitems[1].toolTip = "下一个文件（→）"
            return group
        case .loupeShare:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = self
            item.label = "分享"
            item.toolTip = "分享"
            return item
        case .loupeMore:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多")
            item.label = "更多"
            item.toolTip = "更多操作"
            item.showsIndicator = false
            let m = NSMenu()
            m.addItem(withTitle: "在 Finder 中显示", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            m.addItem(withTitle: "用默认应用打开", action: #selector(openWithDefaultApp(_:)), keyEquivalent: "")
            m.addItem(withTitle: "拷贝路径", action: #selector(copyPath(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "显示文件夹侧栏", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")
            m.addItem(withTitle: "显示简介", action: #selector(toggleInfoPanel(_:)), keyEquivalent: "")
            item.menu = m
            return item
        case .loupeInfo:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "简介")
            item.label = "简介"
            item.toolTip = "文件信息（⌘I）"
            item.action = #selector(toggleInfoPanel(_:))
            item.target = self
            return item
        case .loupeAI:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI 助手")
            item.label = "AI"
            item.toolTip = "AI 助手（⌘J）"
            item.action = #selector(toggleAIPanel(_:))
            item.target = self
            return item
        default:
            return nil
        }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        model.file.map { [$0.url] } ?? []
    }

    @objc func navGroup(_ sender: NSToolbarItemGroup) {
        model.navigate(sender.selectedIndex == 0 ? -1 : 1)
    }

    // MARK: Actions (responder chain targets from the main menu)

    @objc func revealInFinder(_ sender: Any?) {
        guard let u = model.file?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
    @objc func openWithDefaultApp(_ sender: Any?) {
        guard let u = model.file?.url else { return }
        NSWorkspace.shared.open(u)
    }
    @objc func copyPath(_ sender: Any?) {
        guard let u = model.file?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.path, forType: .string)
        model.showNotice("已拷贝路径", style: .success, action: nil)
        let id = model.notice?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.model.notice?.id == id { self?.model.notice = nil }
        }
    }
    @objc func toggleInfoPanel(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
    }
    @objc func toggleAIPanel(_ sender: Any?) {
        setAIPanel(open: aiItem.isCollapsed)
    }

    func setAIPanel(open: Bool) {
        guard aiItem.isCollapsed == open else { return }
        aiItem.animator().isCollapsed = !open
        if !AppEnvironment.isScripted { UserDefaults.standard.set(open, forKey: "aiPanelOpen") }
    }

    var isAIPanelOpen: Bool { !aiItem.isCollapsed }

    @objc func toggleFileSidebar(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateStripWidth() }
    }
    @objc func previousFile(_ sender: Any?) { model.navigate(-1) }
    @objc func nextFile(_ sender: Any?) { model.navigate(1) }
    @objc func closeFile(_ sender: Any?) { closeTabAction(sender) }

    @objc func loupeFormat(_ sender: NSMenuItem) {
        guard let md = model.renderer as? MarkdownRenderer, let command = sender.representedObject as? String else { return }
        switch command {
        case "outline": md.toggleOutline()
        case "source": md.toggleWriteSource()
        default: md.format(command)
        }
    }

    @objc func loupeZoomIn(_ sender: Any?) { model.perform(.zoomIn) }
    @objc func loupeZoomOut(_ sender: Any?) { model.perform(.zoomOut) }
    @objc func loupeActualSize(_ sender: Any?) { model.perform(.actualSize) }
    @objc func loupeZoomToFit(_ sender: Any?) { model.perform(.zoomToFit) }
    @objc func loupeFind(_ sender: Any?) { model.perform(.find) }
    @objc func loupeFindNext(_ sender: Any?) { model.perform(.findNext) }
    @objc func loupeFindPrevious(_ sender: Any?) { model.perform(.findPrevious) }
    @objc func loupeRotateLeft(_ sender: Any?) { model.perform(.rotateLeft) }
    @objc func loupeRotateRight(_ sender: Any?) { model.perform(.rotateRight) }
    @objc func loupeToggleSource(_ sender: Any?) { model.perform(.toggleSource) }
    @objc func loupeToggleWrap(_ sender: Any?) { model.perform(.toggleWrap) }
    @objc func loupePlayPause(_ sender: Any?) { model.perform(.playPause) }
    @objc func loupeSlideshow(_ sender: Any?) { model.perform(.slideshow) }
    @objc func loupeSave(_ sender: Any?) { model.perform(.save) }
    @objc func loupeSaveAs(_ sender: Any?) { model.perform(.saveAs) }
    @objc func loupeExportCSV(_ sender: Any?) { model.perform(.exportCSV) }
    @objc func loupeExportXLSX(_ sender: Any?) { model.perform(.exportXLSX) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasFile = model.file != nil
        switch item.action {
        case #selector(revealInFinder(_:)), #selector(openWithDefaultApp(_:)), #selector(copyPath(_:)):
            return hasFile
        case #selector(previousFile(_:)): return model.canGoBack
        case #selector(nextFile(_:)): return model.canGoForward
        case #selector(toggleInfoPanel(_:)):
            item.title = inspectorItem.isCollapsed ? "显示简介" : "隐藏简介"
            return true
        case #selector(loupeFormat(_:)): return model.renderer is MarkdownRenderer
        case #selector(toggleAIPanel(_:)):
            item.title = aiItem.isCollapsed ? "显示 AI 助手" : "隐藏 AI 助手"
            return true
        case #selector(toggleFileSidebar(_:)):
            item.title = sidebarItem.isCollapsed ? "显示文件夹侧栏" : "隐藏文件夹侧栏"
            return true
        case #selector(loupeZoomIn(_:)): return model.supports(.zoomIn)
        case #selector(loupeZoomOut(_:)): return model.supports(.zoomOut)
        case #selector(loupeActualSize(_:)): return model.supports(.actualSize)
        case #selector(loupeZoomToFit(_:)): return model.supports(.zoomToFit)
        case #selector(loupeFind(_:)): return model.supports(.find)
        case #selector(loupeFindNext(_:)): return model.supports(.findNext)
        case #selector(loupeFindPrevious(_:)): return model.supports(.findPrevious)
        case #selector(loupeRotateLeft(_:)): return model.supports(.rotateLeft)
        case #selector(loupeRotateRight(_:)): return model.supports(.rotateRight)
        case #selector(loupeToggleSource(_:)): return model.supports(.toggleSource)
        case #selector(loupeToggleWrap(_:)): return model.supports(.toggleWrap)
        case #selector(loupePlayPause(_:)): return model.supports(.playPause)
        case #selector(loupeSlideshow(_:)): return model.supports(.slideshow)
        case #selector(loupeSave(_:)): return model.supports(.save)
        case #selector(loupeSaveAs(_:)): return model.supports(.saveAs)
        case #selector(loupeExportCSV(_:)): return model.supports(.exportCSV)
        case #selector(loupeExportXLSX(_:)): return model.supports(.exportXLSX)
        default: return true
        }
    }
}
