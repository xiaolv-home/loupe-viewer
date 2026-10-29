import AppKit
import SwiftUI
import LoupeCore

/// Shared behaviour for renderers offering "tree | source" (JSON, property lists).
@MainActor
class StructuredRenderer: NSObject, ObservableObject {
    @Published var mode = 0 { didSet { applyMode() } }  // 0 = tree, 1 = source
    var tree: TreeView?
    var code: CodeView?
    let container = NSView()
    var summary = ""
    var extraInfo: [InfoItem] = []
    weak var host: RenderHost?
    var sourceText = ""
    var sourceLanguage = "json"
    private var sourceLoaded = false

    func install(tree t: TreeView) {
        tree = t
        for v in [t] as [NSView] { pin(v) }
        applyMode()
    }

    func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    func applyMode() {
        if mode == 1 && !sourceLoaded {
            sourceLoaded = true
            let c = CodeView()
            c.wrap = AppSettings.shared.wrapText
            code = c
            pin(c)
            let text = sourceText
            let lang = sourceLanguage
            Task { await c.setText(text, language: lang, highlight: text.utf8.count <= AppSettings.shared.highlightLimitBytes) }
        }
        tree?.isHidden = mode != 0
        code?.isHidden = mode != 1
        container.window?.makeFirstResponder(mode == 0 ? tree?.outline : code?.textView)
        host?.rendererDidUpdate()
    }

    func cleanupStructured() {
        tree?.detach()
        code?.cancel()
        tree = nil
        code = nil
        sourceText = ""
    }

    func structuredSupports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .toggleSource, .find, .findNext, .findPrevious: return true
        case .toggleWrap: return mode == 1
        default: return false
        }
    }

    func structuredPerform(_ c: ViewerCommand) {
        switch c {
        case .toggleSource: mode = mode == 0 ? 1 : 0
        case .find:
            if mode == 0 { mode = 1 }
            DispatchQueue.main.async { self.code?.showFind() }
        case .findNext: code?.findNext(true)
        case .findPrevious: code?.findNext(false)
        case .toggleWrap: code?.wrap.toggle()
        default: break
        }
    }
}

struct StructuredControls: View {
    @ObservedObject var r: StructuredRenderer
    var body: some View {
        HStack(spacing: 4) {
            LensSegment(options: ["树", "源码"], selection: $r.mode)
            LensButton(symbol: "magnifyingglass", help: "查找（⌘F）") { r.structuredPerform(.find) }
        }
    }
}

@MainActor
final class JSONRenderer: StructuredRenderer, Renderer {
    static let engineName = "JSON"
    static let treeLimit: Int64 = 40 * 1024 * 1024
    static func canHandle(_ file: FileContext) -> Bool { file.size <= treeLimit }

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        let url = file.url
        let result: (JSONValue, String) = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let (text, _) = TextEncodingDetector.decode(data)
            let utf8 = Data(text.utf8)
            return (try JSONParser.parse(utf8), text)
        }.value
        try Task.checkCancellation()
        let (value, text) = result
        // Minified single-line documents are pretty-printed for the source view.
        let lineCount = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if lineCount <= 2 && text.utf8.count > 512 {
            sourceText = JSONWriter.write(value, indent: 0)
            extraInfo.append(InfoItem("源码", "原文件为单行，已格式化显示"))
        } else {
            sourceText = text
        }
        sourceLanguage = "json"
        switch value {
        case .object(let m): summary = "对象 · \(Fmt.number(m.count)) 个键"
        case .array(let a): summary = "数组 · \(Fmt.number(a.count)) 项"
        default: summary = value.typeName
        }
        install(tree: TreeView(root: value, rootName: "根"))
        return container
    }

    func cleanup() { cleanupStructured() }
    var statusText: String { summary }
    var infoSections: [InfoSection] { [InfoSection("结构", [InfoItem("顶层", summary)] + extraInfo)] }
    var controls: AnyView? { AnyView(StructuredControls(r: self)) }
    var initialFirstResponder: NSView? { tree?.outline }
    func supports(_ c: ViewerCommand) -> Bool { structuredSupports(c) }
    func perform(_ c: ViewerCommand) { structuredPerform(c) }
}

@MainActor
final class PlistRenderer: StructuredRenderer, Renderer {
    static let engineName = "Plist"
    static func canHandle(_ file: FileContext) -> Bool { file.size < 64 * 1024 * 1024 }

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        let url = file.url
        let result: (JSONValue, String, String) = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            var format = PropertyListSerialization.PropertyListFormat.xml
            let obj: Any
            do {
                obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            } catch {
                throw RenderError.unreadable("属性列表解析失败")
            }
            // Binary plists are converted to readable XML for the source view.
            let xmlText: String
            if format == .xml {
                xmlText = TextEncodingDetector.decode(data).0
            } else if let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) {
                xmlText = String(decoding: xml, as: UTF8.self)
            } else {
                xmlText = "（无法转换为 XML）"
            }
            let fmtName = format == .binary ? "二进制（bplist00）" : (format == .xml ? "XML" : "OpenStep")
            return (JSONValue.fromPlist(obj), xmlText, fmtName)
        }.value
        try Task.checkCancellation()
        let (value, xml, fmt) = result
        sourceText = xml
        sourceLanguage = "xml"
        extraInfo = [InfoItem("格式", fmt)]
        if fmt.hasPrefix("二进制") { extraInfo.append(InfoItem("源码", "已从二进制转换为 XML")) }
        switch value {
        case .object(let m): summary = "字典 · \(m.count) 个键 · \(fmt)"
        case .array(let a): summary = "数组 · \(a.count) 项 · \(fmt)"
        default: summary = fmt
        }
        install(tree: TreeView(root: value, rootName: "Root"))
        return container
    }

    func cleanup() { cleanupStructured() }
    var statusText: String { summary }
    var infoSections: [InfoSection] { [InfoSection("属性列表", extraInfo)] }
    var controls: AnyView? { AnyView(StructuredControls(r: self)) }
    var initialFirstResponder: NSView? { tree?.outline }
    func supports(_ c: ViewerCommand) -> Bool { structuredSupports(c) }
    func perform(_ c: ViewerCommand) { structuredPerform(c) }
}
