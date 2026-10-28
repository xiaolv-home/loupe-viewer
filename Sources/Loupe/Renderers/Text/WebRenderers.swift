import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import LoupeCore

/// Common shell for web-rendered documents: rendered/source toggle, find bar, zoom.
@MainActor
class WebDocumentRenderer: NSObject, ObservableObject {
    @Published var mode = 0 { didSet { applyMode() } } // 0 rendered, 1 source (or editor)
    /// Markdown: mode 1 is an editor beside a live preview instead of read-only source.
    var editable = false
    private var split: NSSplitView?
    var web: LoupeWebView?
    let navigator = WebNavigator()
    let container = NSView()
    private let body = NSView()
    private let findBar = WebFindBar()
    private var findHeight: NSLayoutConstraint!
    private(set) var code: CodeView?
    var sourceText = ""
    var sourceLanguage = "markdown"
    weak var host: RenderHost?

    func buildShell(_ wv: LoupeWebView) {
        web = wv
        findBar.webView = wv
        findBar.onClose = { [weak self] in self?.hideFind() }
        for v in [findBar, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBar.isHidden = true
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findHeight,
            body.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        if editable {
            // Editor (added on first use) and preview side by side; the editor pane stays
            // hidden while reading, which an NSSplitView treats as collapsed.
            let sv = NSSplitView()
            sv.isVertical = true
            sv.dividerStyle = .thin
            sv.addArrangedSubview(wv)
            split = sv
            pin(sv)
        } else {
            pin(wv)
        }
    }

    /// Text as it is now (the editor's, if editing has started).
    var currentSource: String { code?.textView.string ?? sourceText }

    /// Called after edits settle; subclasses re-render the preview.
    func sourceDidChange(_ text: String) {}

    private func makeEditor() -> CodeView {
        let c = CodeView()
        c.wrap = true
        c.makeEditable(language: sourceLanguage)
        c.onEdit = { [weak self] text in
            guard let self else { return }
            self.sourceText = text
            self.sourceDidChange(text)
        }
        c.scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorScrolled), name: NSView.boundsDidChangeNotification, object: c.scrollView.contentView)
        return c
    }

    /// The preview follows the editor at the same relative position.
    @objc private func editorScrolled() {
        guard let c = code, let web, mode == 1 else { return }
        let clip = c.scrollView.contentView
        let total = max(1, c.textView.frame.height - clip.bounds.height)
        let f = max(0, min(1, clip.bounds.origin.y / total))
        web.evaluateJavaScript("window.scrollTo(0, \(f) * Math.max(0, document.documentElement.scrollHeight - window.innerHeight))")
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }

    private func applyMode() {
        if editable, let split {
            if mode == 1 && code == nil {
                let c = makeEditor()
                code = c
                split.insertArrangedSubview(c, at: 0)
                let t = sourceText, l = sourceLanguage
                Task { await c.setText(t, language: l, highlight: t.utf8.count <= AppSettings.shared.highlightLimitBytes) }
                split.layoutSubtreeIfNeeded()
                split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
            }
            code?.isHidden = mode != 1
            split.adjustSubviews()
            if mode == 1, let c = code, c.frame.width < 40 { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
            container.window?.makeFirstResponder(mode == 0 ? web : code?.textView)
            host?.rendererDidUpdate()
            return
        }
        if mode == 1 && code == nil {
            let c = CodeView()
            c.wrap = AppSettings.shared.wrapText
            code = c
            pin(c)
            let t = sourceText, l = sourceLanguage
            Task { await c.setText(t, language: l, highlight: t.utf8.count <= AppSettings.shared.highlightLimitBytes) }
        }
        web?.isHidden = mode != 0
        code?.isHidden = mode != 1
        container.window?.makeFirstResponder(mode == 0 ? web : code?.textView)
        host?.rendererDidUpdate()
    }

    func showFind() {
        if mode == 1 { code?.showFind(); return }
        findBar.isHidden = false
        findHeight.constant = 38
        container.window?.makeFirstResponder(findBar.field)
    }

    func hideFind() {
        findBar.isHidden = true
        findHeight.constant = 0
        container.window?.makeFirstResponder(web)
    }

    func cleanupWeb() {
        NotificationCenter.default.removeObserver(self)
        code?.cancel()
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web?.loadHTMLString("", baseURL: nil)
        web?.removeFromSuperview()
        web = nil
    }

    func webSupports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .toggleSource, .find, .findNext, .findPrevious, .zoomIn, .zoomOut, .actualSize: return true
        case .toggleWrap: return mode == 1
        default: return false
        }
    }

    func webPerform(_ c: ViewerCommand) {
        switch c {
        case .toggleSource: mode = mode == 0 ? 1 : 0
        case .find: showFind()
        case .findNext: mode == 1 ? code?.findNext(true) : findBar.next()
        case .findPrevious: mode == 1 ? code?.findNext(false) : findBar.previous()
        case .zoomIn: if mode == 0 { web?.pageZoom = min(3, (web?.pageZoom ?? 1) * 1.1) } else { code?.zoom(by: 1) }
        case .zoomOut: if mode == 0 { web?.pageZoom = max(0.4, (web?.pageZoom ?? 1) / 1.1) } else { code?.zoom(by: -1) }
        case .actualSize: web?.pageZoom = 1; code?.setFontSize(12.5)
        case .toggleWrap: code?.wrap.toggle()
        default: break
        }
    }
}

struct WebControls: View {
    @ObservedObject var r: WebDocumentRenderer
    var labels = ["渲染", "源码"]
    var body: some View {
        HStack(spacing: 4) {
            LensSegment(options: labels, selection: $r.mode)
            LensButton(symbol: "magnifyingglass", help: "查找（⌘F）") { r.showFind() }
        }
    }
}

@MainActor
final class MarkdownRenderer: WebDocumentRenderer, Renderer {
    static let engineName = "WebKit"
    static func canHandle(_ file: FileContext) -> Bool { file.size < 32 * 1024 * 1024 }
    private var words = 0
    private var url: URL?
    /// Encoding and line endings the file is saved back with.
    private var format = TextFileFormat.utf8LF
    /// The text as last read or saved; edits are unsaved while the editor differs from it.
    private var savedText = ""

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        let url = file.url
        self.url = url
        let (text, fmt) = try await Task.detached { try TextFileFormat.read(url) }.value
        format = fmt
        savedText = text
        sourceText = text
        sourceLanguage = "markdown"
        editable = true
        let wv = await WebFactory.make(javaScript: true)
        navigator.host = host
        wv.navigationDelegate = navigator
        wv.uiDelegate = navigator
        buildShell(wv)
        let template = AppResources.webRoot.appendingPathComponent("markdown.html")
        guard let html = try? String(contentsOf: template, encoding: .utf8) else { throw RenderError.unsupported("缺少 Markdown 模板资源") }
        // Base URL is the document's folder so relative images resolve through loupe://file/.
        let base = LoupeSchemeHandler.url(forFile: url.deletingLastPathComponent()).appendingPathComponent("/")
        try await navigator.load(wv) { wv.loadHTMLString(html, baseURL: base) }
        guard await render(text) else { throw RenderError.unreadable("Markdown 渲染脚本执行失败") }
        return container
    }

    @discardableResult
    private func render(_ text: String) async -> Bool {
        guard let web else { return false }
        let json = String(data: (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "[\"\"]"
        let result = try? await web.evaluateJavaScript("loupeRender(\(json)[0])")
        words = text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        return result != nil
    }

    /// Live preview while editing.
    override func sourceDidChange(_ text: String) {
        Task { await render(text) }
        updateEdited()
    }

    private func updateEdited() {
        host?.window?.isDocumentEdited = hasUnsavedChanges
        host?.rendererDidUpdate()
    }

    var hasUnsavedChanges: Bool { currentSource != savedText }

    func saveChanges(completion: @escaping (Bool) -> Void) {
        guard let url else { completion(false); return }
        write(to: url, completion: completion)
    }

    private func write(to dest: URL, completion: ((Bool) -> Void)? = nil) {
        let text = currentSource
        do {
            let kept = try format.write(text, to: dest)
            if !kept {
                format = TextFileFormat(encoding: .utf8, lineEnding: format.lineEnding)
                host?.showNotice("已保存。部分字符无法用原编码（\(format.encoding.name)）表示，文件已改为 UTF-8。", style: .warning, action: nil)
            }
            if dest == url { savedText = text }
            sourceText = text
            updateEdited()
            completion?(true)
        } catch {
            host?.showNotice("保存失败：\(error.localizedDescription)。原文件没有被改动。", style: .warning, action: nil)
            completion?(false)
        }
    }

    private func saveAs() {
        guard let url, let window = host?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " 副本.md"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let dest = panel.url else { return }
            self.write(to: dest) { ok in if ok { self.host?.open(dest) } }
        }
    }

    func cleanup() { cleanupWeb() }
    var statusText: String {
        let lines = currentSource.split(separator: "\n", omittingEmptySubsequences: false).count
        var s = "\(Fmt.number(lines)) 行 · \(Fmt.number(words)) 字符"
        if mode == 1 { s += " · 编辑中" }
        if hasUnsavedChanges { s += " · ● 已修改（⌘S 保存）" }
        return s
    }
    var infoSections: [InfoSection] {
        [InfoSection("Markdown", [InfoItem("字符数", Fmt.number(words)),
                                  InfoItem("编码", format.encoding.name + (format.lineEnding == "\r\n" ? " · CRLF" : format.lineEnding == "\r" ? " · CR" : " · LF")),
                                  InfoItem("渲染", "markdown-it · KaTeX · Mermaid（本地）"),
                                  InfoItem("安全", "已净化 HTML，远程资源已阻止")])]
    }
    var controls: AnyView? { AnyView(WebControls(r: self, labels: ["渲染", "编辑"])) }
    var initialFirstResponder: NSView? { web }
    func supports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .save: return hasUnsavedChanges
        case .saveAs: return true
        default: return webSupports(c)
        }
    }
    func perform(_ c: ViewerCommand) {
        switch c {
        case .save: saveChanges { _ in }
        case .saveAs: saveAs()
        default: webPerform(c)
        }
    }
}

/// HTML (and SVG fallback) in a web view with JavaScript disabled and remote loads blocked.
@MainActor
final class HTMLRenderer: WebDocumentRenderer, Renderer {
    static let engineName = "WebKit"
    static func canHandle(_ file: FileContext) -> Bool { file.size < 64 * 1024 * 1024 }
    private var isSVG = false
    private var title = ""
    /// Local pages run their scripts (offline, confined to their folder) unless turned off.
    private var scripts = false

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        isSVG = file.format.family == .svg
        scripts = !isSVG && AppSettings.shared.webPagesRunScripts
        let url = file.url
        sourceText = (try? await Task.detached { TextEncodingDetector.decode(try Data(contentsOf: url)).0 }.value) ?? ""
        sourceLanguage = isSVG ? "xml" : "html"
        let folder = url.deletingLastPathComponent()
        let wv = await WebFactory.make(javaScript: scripts, fileRoot: scripts ? folder : nil, keepsData: scripts && !AppEnvironment.isScripted)
        navigator.host = host
        if scripts { navigator.siteRoot = folder }
        wv.navigationDelegate = navigator
        wv.uiDelegate = navigator
        buildShell(wv)
        let target = LoupeSchemeHandler.url(forFile: url)
        if isSVG {
            // <img> never runs SVG scripts and scales cleanly.
            let html = """
            <!doctype html><meta charset="utf-8"><style>html,body{margin:0;height:100%;background:transparent}
            body{display:flex;align-items:center;justify-content:center}
            img{max-width:calc(100% - 64px);max-height:calc(100% - 64px);min-width:64px}</style>
            <img src="\(target.absoluteString)">
            """
            try await navigator.load(wv) { wv.loadHTMLString(html, baseURL: URL(string: "loupe://app/")) }
        } else {
            wv.setValue(true, forKey: "drawsBackground")
            try await navigator.load(wv) { wv.load(URLRequest(url: target)) }
            title = wv.title ?? ""
        }
        return container
    }

    func cleanup() { cleanupWeb() }
    var presentation: StagePresentation { isSVG ? .bleed : .sheet }
    var controlsPlacement: ControlsPlacement { isSVG ? .floating : .strip }
    var statusText: String {
        if isSVG { return "矢量图 · 脚本已禁用" }
        return (title.isEmpty ? "" : "「\(title)」 · ") + (scripts ? "脚本已运行 · 已断网" : "JavaScript 已禁用")
    }
    var infoSections: [InfoSection] {
        [InfoSection(isSVG ? "SVG" : "网页", [InfoItem("标题", title.isEmpty ? "—" : title),
                                              InfoItem("安全", scripts ? "脚本只能读取本网页所在文件夹，不能联网、不能弹窗；本地存储（如阅读进度）会保留"
                                                                        : "JavaScript 已禁用，远程资源已阻止")])]
    }
    var controls: AnyView? { AnyView(WebControls(r: self, labels: isSVG ? ["图像", "源码"] : ["网页", "源码"])) }
    var initialFirstResponder: NSView? { web }
    func supports(_ c: ViewerCommand) -> Bool { webSupports(c) }
    func perform(_ c: ViewerCommand) { webPerform(c) }
}
