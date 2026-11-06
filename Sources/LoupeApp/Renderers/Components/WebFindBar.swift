import AppKit
import WebKit
import UniformTypeIdentifiers
import LoupeCore

/// A page that does its own searching, and can replace (the Markdown writer).
@MainActor
protocol WebFindDriver: AnyObject {
    func search(_ query: String, step: Int) async -> (current: Int, total: Int)
    func replaceCurrent(_ query: String, with replacement: String) async -> (current: Int, total: Int)
    func replaceAll(_ query: String, with replacement: String) async -> Int
    func endSearch()
}

/// Compact find bar for web content: the browser's own find, or the page's where it has one,
/// which adds a counter, searching as you type, and replacing.
final class WebFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let replaceField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private var replaceRow: NSStackView!
    weak var webView: WKWebView?
    weak var driver: WebFindDriver?
    var onClose: (() -> Void)?

    static let height: CGFloat = 38
    static let heightWithReplace: CGFloat = 70

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "在页面中查找"
        field.target = self
        field.action = #selector(next)
        field.sendsWholeSearchString = true
        field.delegate = self
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        replaceField.placeholderString = "替换为"
        replaceField.target = self
        replaceField.action = #selector(replaceOne)
        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "上一个")!, target: self, action: #selector(previous))
        let nxt = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "下一个")!, target: self, action: #selector(next))
        let done = NSButton(title: "完成", target: self, action: #selector(close))
        let one = NSButton(title: "替换", target: self, action: #selector(replaceOne))
        let all = NSButton(title: "全部替换", target: self, action: #selector(replaceEvery))
        for b in [prev, nxt, done, one, all] { b.bezelStyle = .accessoryBarAction; b.controlSize = .small }
        let findRow = NSStackView(views: [field, status, prev, nxt, done])
        findRow.spacing = 6
        replaceRow = NSStackView(views: [replaceField, one, all])
        replaceRow.spacing = 6
        replaceRow.isHidden = true
        let stack = NSStackView(views: [findRow, replaceRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            replaceField.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
        wantsLayer = true
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        layer?.backgroundColor = resolved(Theme.surfaceRaised)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    var showsReplace: Bool {
        get { !replaceRow.isHidden }
        set { replaceRow.isHidden = !newValue }
    }

    @objc func next() { find(step: 1) }
    @objc func previous() { find(step: -1) }
    @objc func close() { onClose?() }

    func controlTextDidChange(_ note: Notification) {
        if note.object as? NSSearchField === field, driver != nil { find(step: 0) }
    }

    private func show(_ r: (current: Int, total: Int)) {
        status.stringValue = field.stringValue.isEmpty ? "" : r.total == 0 ? "无结果" : "\(r.current) / \(r.total)"
    }

    private func find(step: Int) {
        if let driver {
            Task { @MainActor in show(await driver.search(field.stringValue, step: step)) }
            return
        }
        guard let wv = webView, !field.stringValue.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = step < 0
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(field.stringValue, configuration: cfg) { [weak self] r in
            self?.status.stringValue = r.matchFound ? "" : "无结果"
        }
    }

    @objc private func replaceOne() {
        guard let driver, !field.stringValue.isEmpty else { return }
        Task { @MainActor in show(await driver.replaceCurrent(field.stringValue, with: replaceField.stringValue)) }
    }

    @objc private func replaceEvery() {
        guard let driver, !field.stringValue.isEmpty else { return }
        Task { @MainActor in
            let n = await driver.replaceAll(field.stringValue, with: replaceField.stringValue)
            status.stringValue = n == 0 ? "无结果" : "已替换 \(n) 处"
        }
    }

    #if DEBUG
        func debugSet(find: String, replace: String) {
            field.stringValue = find
            replaceField.stringValue = replace
        }
    #endif
}
