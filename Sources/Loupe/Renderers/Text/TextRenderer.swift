import AppKit
import SwiftUI
import LoupeCore

/// Plain text and source code. Up to `largeThreshold` bytes the file is shown in a
/// highlighted NSTextView; beyond that a virtualised line view keeps memory flat.
@MainActor
final class TextRenderer: NSObject, Renderer, ObservableObject {
    static let engineName = "TextKit"
    static let largeThreshold = 16 * 1024 * 1024
    static func canHandle(_ file: FileContext) -> Bool { !file.isDirectory }

    @Published var wrap = AppSettings.shared.wrapText
    @Published var encodingName = ""
    @Published var highlightState = ""
    private var file: FileContext?
    private var data = Data()
    private var codeView: CodeView?
    private var largeView: LargeTextView?
    private var language: String?
    private var lines = 0
    private weak var host: RenderHost?
    private var detected: DetectedEncoding?
    private var loadTask: Task<Void, Never>?

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        self.host = host
        language = file.format.language ?? "plain"
        if file.size > Int64(Self.largeThreshold) {
            return try await makeLarge(file, host: host)
        }
        let url = file.url
        let d: Data
        do { d = try await Task.detached { try Data(contentsOf: url, options: [.mappedIfSafe]) }.value }
        catch { throw RenderError.unreadable("无法读取文件：\(error.localizedDescription)") }
        try Task.checkCancellation()
        data = d
        let enc = await Task.detached { TextEncodingDetector.detect(d) }.value
        detected = enc
        let view = CodeView()
        view.wrap = wrap
        codeView = view
        await apply(encoding: enc)
        return view
    }

    private func apply(encoding enc: DetectedEncoding) async {
        guard let view = codeView else { return }
        let d = data
        let text = await Task.detached { TextEncodingDetector.decode(d, as: enc) }.value
        encodingName = enc.name
        let lang = language ?? "plain"
        let canHighlight = SyntaxHighlighter.forLanguage(lang) != nil
        let withinLimit = d.count <= AppSettings.shared.highlightLimitBytes
        highlightState = !canHighlight ? "" : (withinLimit ? "" : "高亮已关闭（超过 \(Int(AppSettings.shared.highlightLimitMB)) MB）")
        await view.setText(text, language: lang, highlight: canHighlight && withinLimit)
        lines = view.lineCount
        host?.rendererDidUpdate()
    }

    private func makeLarge(_ file: FileContext, host: RenderHost) async throws -> NSView {
        let url = file.url
        let idx: LineIndex
        do { idx = try LineIndex(url: url) } catch { throw RenderError.unreadable("无法映射文件：\(error.localizedDescription)") }
        encodingName = idx.encoding.name
        highlightState = "大文件模式 · 高亮已关闭"
        let view = LargeTextView(index: idx)
        largeView = view
        host.reportProgress(0, label: "正在索引行…")
        // Index the first chunk synchronously-ish so content appears immediately, rest streams in.
        loadTask = Task { [weak self, weak view] in
            var lastUpdate = Date.distantPast
            await Task.detached(priority: .userInitiated) {
                idx.build(progress: { frac, _ in
                    let now = Date()
                    guard now.timeIntervalSince(lastUpdate) > 0.15 || frac >= 1 else { return }
                    lastUpdate = now
                    Task { @MainActor in
                        guard let self, let view else { return }
                        view.reload()
                        self.lines = idx.lineCount
                        if frac < 1 {
                            self.highlightState = "正在索引 \(Int(frac * 100))%"
                        } else {
                            self.highlightState = "大文件模式 · 高亮已关闭"
                        }
                        self.host?.rendererDidUpdate()
                    }
                }, isCancelled: { Task.isCancelled })
            }.value
        }
        // Return as soon as the first lines are indexed.
        try await Task.sleep(nanoseconds: 120_000_000)
        host.reportProgress(nil, label: nil)
        view.reload()
        return view
    }

    func cleanup() {
        loadTask?.cancel()
        codeView?.cancel()
        largeView?.stop()
        codeView = nil
        largeView = nil
        data = Data()
    }

    var statusText: String {
        var parts = ["\(Fmt.number(lines)) 行"]
        if let l = language, l != "plain" { parts.append(ExtensionTable.languageDisplayName(l)) }
        if isLarge, !encodingName.isEmpty { parts.append(encodingName) }
        return parts.joined(separator: " · ")
    }

    var infoSections: [InfoSection] {
        var items = [InfoItem("行数", Fmt.number(lines)), InfoItem("编码", encodingName)]
        if let l = language { items.append(InfoItem("语言", ExtensionTable.languageDisplayName(l))) }
        if !highlightState.isEmpty { items.append(InfoItem("显示", highlightState)) }
        return [InfoSection("文本", items)]
    }

    var controls: AnyView? { AnyView(TextControls(r: self)) }
    var initialFirstResponder: NSView? { codeView?.textView ?? largeView?.tableView }

    func supports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .find, .findNext, .findPrevious: return true
        case .toggleWrap, .zoomIn, .zoomOut, .actualSize: return codeView != nil
        default: return false
        }
    }

    func perform(_ c: ViewerCommand) {
        switch c {
        case .find: codeView?.showFind() ?? largeView?.showSearch()
        case .findNext: codeView?.findNext(true) ?? largeView?.step(1)
        case .findPrevious: codeView?.findNext(false) ?? largeView?.step(-1)
        case .toggleWrap: setWrap(!wrap)
        case .zoomIn: codeView?.zoom(by: 1)
        case .zoomOut: codeView?.zoom(by: -1)
        case .actualSize: codeView?.setFontSize(12.5)
        default: break
        }
    }

    func setWrap(_ w: Bool) {
        wrap = w
        codeView?.wrap = w
    }

    var isLarge: Bool { largeView != nil }

    func reinterpret(_ enc: DetectedEncoding?) {
        guard codeView != nil else { return }
        Task { await apply(encoding: enc ?? detected ?? .utf8) }
    }

    static let encodingChoices: [DetectedEncoding] = [
        .utf8, .gb18030,
        DetectedEncoding(TextEncodingDetector.big5, "Big5"),
        DetectedEncoding(.shiftJIS, "Shift_JIS"),
        DetectedEncoding(TextEncodingDetector.eucKR, "EUC-KR"),
        DetectedEncoding(.utf16LittleEndian, "UTF-16 LE", unit: 2),
        DetectedEncoding(.utf16BigEndian, "UTF-16 BE", unit: 2, bigEndian: true),
        DetectedEncoding(.windowsCP1252, "Windows-1252"),
        DetectedEncoding(.isoLatin1, "ISO-8859-1")
    ]
}

private struct TextControls: View {
    @ObservedObject var r: TextRenderer

    var body: some View {
        HStack(spacing: 4) {
            if !r.highlightState.isEmpty {
                Text(r.highlightState).font(Theme.mono(10.5)).foregroundStyle(.secondary)
                LensDivider()
            }
            if !r.isLarge {
                Menu {
                    Button("自动检测") { r.reinterpret(nil) }
                    Divider()
                    ForEach(TextRenderer.encodingChoices, id: \.name) { e in
                        Button(e.name) { r.reinterpret(e) }
                    }
                } label: {
                    Text(r.encodingName).font(Theme.mono(10.5, .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("文本编码 · 乱码时可手动切换")
                LensButton(symbol: "text.word.spacing", help: "自动换行（⌥⌘L）", active: r.wrap) { r.setWrap(!r.wrap) }
            }
            LensButton(symbol: "magnifyingglass", help: "查找（⌘F）") { r.perform(.find) }
        }
    }
}
