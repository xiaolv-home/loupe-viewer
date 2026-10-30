import AppKit
import WebKit
import UniformTypeIdentifiers
import LoupeCore

enum AppResources {
    /// Bundled web assets: Contents/Resources/web in the app, or the source tree during development.
    static let webRoot: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"), FileManager.default.fileExists(atPath: r.appendingPathComponent("markdown.html").path) {
            return r
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/web")
    }()
}

/// Serves `loupe://app/<path>` from the bundled web assets and `loupe://file/<abs path>`
/// from disk, so pages never need file:// access and nothing ever touches the network.
final class LoupeSchemeHandler: NSObject, WKURLSchemeHandler {
    private var active = Set<ObjectIdentifier>()
    /// `loupe://file/` only serves files inside this folder, after resolving symlinks.
    /// `nil` serves nothing (fail closed). Markdown and HTML always pass the document's folder.
    let fileRoot: URL?

    init(fileRoot: URL? = nil) {
        self.fileRoot = fileRoot?.standardizedFileURL
        super.init()
    }

    func allows(_ fileURL: URL) -> Bool {
        guard let root = fileRoot else { return false }
        return FileAccessPolicy.fileInsideRoot(fileURL, root: root) != nil
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let located = Self.resolve(url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let fileURL: URL
        if url.host == "file" {
            guard let root = fileRoot, let limited = FileAccessPolicy.fileInsideRoot(located, root: root) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            fileURL = limited
        } else {
            fileURL = located
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
            DispatchQueue.main.async {
                guard self.active.remove(id) != nil else { return }
                guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
                let ext = fileURL.pathExtension.lowercased()
                var mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                if ext == "js" { mime = "text/javascript" }
                if ext == "md" || ext == "markdown" { mime = "text/plain" }
                var encoding: String?
                if mime.hasPrefix("text/") || mime.contains("xml") || mime.contains("javascript") {
                    let enc = TextEncodingDetector.detect(data.prefix(64 * 1024))
                    encoding = CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(enc.encoding.rawValue)) as String?
                }
                let resp = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: encoding)
                task.didReceive(resp)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    static func resolve(_ url: URL) -> URL? {
        let path = url.path.removingPercentEncoding ?? url.path
        switch url.host {
        case "app":
            return FileAccessPolicy.bundledFile(root: AppResources.webRoot, relativePath: sharedVendorPath(path))
        case "file":
            return URL(fileURLWithPath: path)
        default:
            return nil
        }
    }

    /// The Markdown writer (Vditor) asks for KaTeX, Mermaid and highlight.js under its own
    /// folder; the copies Loupe already ships (newer, same APIs) serve those requests.
    static func sharedVendorPath(_ path: String) -> String {
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let prefix = "vditor/dist/js/"
        guard p.hasPrefix(prefix) else { return path }
        let rest = String(p.dropFirst(prefix.count))
        switch rest {
        case "mermaid/mermaid.min.js": return "vendor/mermaid.min.js"
        case "highlight.js/highlight.min.js": return "vendor/highlight.min.js"
        case "katex/katex.min.js", "katex/katex.min.css": return "vendor/" + rest
        default: return rest.hasPrefix("katex/fonts/") ? "vendor/" + rest : path
        }
    }

    static func url(forFile file: URL) -> URL {
        var c = URLComponents()
        c.scheme = "loupe"
        c.host = "file"
        c.path = file.path
        return c.url!
    }
}

/// Web view that never accepts drops (the window handles them) and never opens new windows.
final class LoupeWebView: WKWebView {
    /// The Markdown writer takes pictures dropped into the text; every other page leaves drops
    /// to the window (which opens the file).
    var acceptsFileDrops = false {
        didSet { if acceptsFileDrops { registerForDraggedTypes([.fileURL, .png, .tiff, .string, .html]) } }
    }
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        if acceptsFileDrops { super.registerForDraggedTypes(newTypes) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFileDrops ? super.draggingEntered(sender) : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsFileDrops ? super.performDragOperation(sender) : false
    }
}

@MainActor
enum WebFactory {
    private static var ruleList: WKContentRuleList?

    /// Blocks every remote load. Compiled once and cached by WebKit.
    /// A failed compile is not cached: the page must not load without the rules.
    static func blockRemoteRules() async throws -> WKContentRuleList {
        if let r = ruleList { return r }
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
        let list: WKContentRuleList? = await withCheckedContinuation { cont in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "loupe-block-remote-v2", encodedContentRuleList: json) { list, error in
                if error != nil { cont.resume(returning: nil) } else { cont.resume(returning: list) }
            }
        }
        guard let list else { throw RenderError.unreadable("无法启用网页断网规则，已停止显示此页面") }
        ruleList = list
        return list
    }

    /// Storage for local pages that run scripts, kept between launches (a reader's progress and
    /// bookmarks live in localStorage). Separate from everything else; never touches the network.
    static let localPagesStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6B1F3C2E-4A5D-4E8B-9C7A-1D2E3F405A6B")!)

    /// `fileRoot` limits which local files the page may load; `keepsData` keeps its
    /// localStorage / IndexedDB between launches.
    static func make(javaScript: Bool, fileRoot: URL? = nil, keepsData: Bool = false) async throws -> LoupeWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(LoupeSchemeHandler(fileRoot: fileRoot), forURLScheme: "loupe")
        cfg.websiteDataStore = keepsData ? localPagesStore : .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.isFraudulentWebsiteWarningEnabled = false
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let rules = try await blockRemoteRules()
        cfg.userContentController.add(rules)
        let wv = LoupeWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        wv.allowsMagnification = true
        wv.allowsBackForwardNavigationGestures = false
        return wv
    }
}

/// Navigation policy shared by Markdown and HTML: only the initial page loads; links are
/// either opened in Loupe (local files) or offered to the browser explicitly.
@MainActor
final class WebNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var host: RenderHost?
    var onFinish: (() -> Void)?
    var onFail: ((Error) -> Void)?
    /// A local web app's folder: its own pages open in place instead of as separate files.
    var siteRoot: URL?

    private func isSitePage(_ url: URL) -> Bool {
        guard let root = siteRoot?.standardizedFileURL, url.scheme == "loupe", url.host == "file",
              let f = LoupeSchemeHandler.resolve(url)?.standardizedFileURL else { return false }
        return ["html", "htm", "xhtml"].contains(f.pathExtension.lowercased()) && f.path.hasPrefix(root.path + "/")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        guard action.navigationType == .linkActivated else {
            // Scripts and frames may move between local pages, never out to the network
            // (that could carry data away).
            let scheme = url.scheme?.lowercased() ?? ""
            decisionHandler(["loupe", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            return
        }
        if isSitePage(url) {
            decisionHandler(.allow)
            return
        }
        // In-page anchors.
        if let cur = webView.url, url.fragment != nil, url.absoluteString.hasPrefix(cur.absoluteString.components(separatedBy: "#")[0]) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.scheme == "loupe", url.host == "file", let f = LoupeSchemeHandler.resolve(url) {
            host?.open(f)
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            host?.showNotice("链接不会自动打开：\(url.absoluteString)", style: .info,
                             action: NoticeAction(title: "在浏览器中打开") { NSWorkspace.shared.open(url) })
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(); onFinish = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFail?(error); onFail = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFail?(error); onFail = nil }
    /// Links meant for a new window: the site's own pages open in place, local files in Loupe,
    /// web addresses only on request.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.navigationType == .linkActivated || navigationAction.sourceFrame.isMainFrame, let url = navigationAction.request.url else { return nil }
        if isSitePage(url) {
            webView.load(URLRequest(url: url))
        } else if url.scheme == "loupe", url.host == "file", let f = LoupeSchemeHandler.resolve(url) {
            host?.open(f)
        } else if navigationAction.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            host?.showNotice("链接不会自动打开：\(url.absoluteString)", style: .info,
                             action: NoticeAction(title: "在浏览器中打开") { NSWorkspace.shared.open(url) })
        }
        return nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        host?.showNotice("网页内容进程意外退出，已停止显示。", style: .warning, action: nil)
    }

    /// Loads and waits until the page finished (or failed / timed out).
    func load(_ wv: WKWebView, _ start: () -> Void, timeout: Double = 15) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            onFinish = { if !done { done = true; cont.resume() } }
            onFail = { e in if !done { done = true; cont.resume(throwing: e) } }
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !done { done = true; cont.resume(throwing: RenderError.unreadable("网页载入超时")) }
            }
        }
    }
}

/// Compact find bar for web content.
final class WebFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    weak var webView: WKWebView?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "在页面中查找"
        field.target = self
        field.action = #selector(next)
        field.sendsWholeSearchString = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "上一个")!, target: self, action: #selector(previous))
        let nxt = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "下一个")!, target: self, action: #selector(next))
        let done = NSButton(title: "完成", target: self, action: #selector(close))
        for b in [prev, nxt, done] { b.bezelStyle = .accessoryBarAction; b.controlSize = .small }
        let stack = NSStackView(views: [field, status, prev, nxt, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        wantsLayer = true
        layer?.backgroundColor = Theme.surfaceRaised.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func next() { find(backwards: false) }
    @objc func previous() { find(backwards: true) }
    @objc func close() { onClose?() }

    private func find(backwards: Bool) {
        guard let wv = webView, !field.stringValue.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(field.stringValue, configuration: cfg) { [weak self] r in
            self?.status.stringValue = r.matchFound ? "" : "无结果"
        }
    }
}
