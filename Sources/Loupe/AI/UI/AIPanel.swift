import SwiftUI
import AppKit
import LoupeCore

/// The AI side panel: where requests go (本地 / 云端), the conversation, and the composer.
struct AIPanel: View {
    @ObservedObject var session: AISession
    @ObservedObject var config = AIConfig.shared
    @ObservedObject var skills = AISkills.shared
    @ObservedObject var tabs: TabList
    @StateObject private var models = AIModelList()
    @State private var inputHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.showHistory { AIHistoryView(session: session, close: { session.showHistory = false }) }
            else if session.isEmpty { AIWelcome(session: session, tabs: tabs, showHistory: { session.showHistory = true }) }
            else { AITranscript(session: session) }
            Divider()
            composer
        }
        .background(Color(nsColor: Theme.surface))
        .onAppear { models.refresh() }
        .onChange(of: config.mode) { _, _ in models.refresh() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(session.showHistory ? "历史对话" : (session.conversation?.title ?? "AI 助手"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer()
                Button { session.showHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(session.showHistory ? Theme.ember : Color.secondary)
                }
                .buttonStyle(.borderless).help("历史对话")
                Button { session.newChat(); session.showHistory = false } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("新对话").disabled(session.isEmpty && !session.running && !session.showHistory)
                Menu {
                    Button("技能库…") { AISkillsWindow.show() }
                    Button("AI 设置…") { AppDelegate.showAISettings() }
                    if let c = session.conversation {
                        Divider()
                        Button("删除当前对话") { session.deleteConversation(c.id) }.disabled(session.running)
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("技能与设置")
            }
            HStack(spacing: 8) {
                Picker("", selection: $config.mode) {
                    Text("本地").tag(AIConfig.Mode.local)
                    Text("云端").tag(AIConfig.Mode.cloud)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 104).controlSize(.small)
                modelMenu
            }
            privacyLine
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 9)
    }

    private var modelMenu: some View {
        Menu {
            if config.mode == .local {
                if models.loading { Text("正在查找本地模型…") }
                else if models.models.isEmpty { Text(models.error ?? "没有找到本地模型") }
                ForEach(models.models, id: \.self) { m in
                    Button { config.localModel = m } label: { Text((m == config.localModel ? "✓ " : "　") + m) }
                }
            } else {
                Section("服务") {
                    ForEach(CloudProvider.all) { p in
                        Button { config.providerID = p.id; models.refresh() } label: {
                            Text((p.id == config.providerID ? "✓ " : "　") + p.name + (config.apiKey(p) == nil ? "（未填 Key）" : ""))
                        }
                    }
                }
                if !models.models.isEmpty {
                    Section("模型") {
                        ForEach(models.models.prefix(40), id: \.self) { m in
                            Button { config.cloudModels[config.providerID] = m } label: {
                                Text((m == config.cloudModel(config.provider) ? "✓ " : "　") + m)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("刷新模型列表") { models.refresh() }
            Button("AI 设置…") { AppDelegate.showAISettings() }
        } label: {
            Text(config.summary.components(separatedBy: " · ").dropFirst().joined(separator: " · "))
                .font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
    }

    private var privacyLine: some View {
        HStack(spacing: 5) {
            if config.mode == .local {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("全部在这台 Mac 上处理，文件内容不出本机")
            } else {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 9.5))
                Text("会把文件内容发给 \(config.provider.name.components(separatedBy: "（").first!)，敏感文件请用本地")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(config.mode == .local ? Color.secondary : Theme.ember)
        .lineLimit(1)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = session.pinnedSkill {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9.5))
                    Text("技能：\(s.name)").font(.system(size: 11, weight: .medium))
                    Button { session.pinnedSkill = nil } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Theme.emberSoft))
                .foregroundStyle(Theme.ember)
            }
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.attachments) { a in
                            AIThumbnail(base64: a.thumbnail, size: 44)
                                .overlay(alignment: .topTrailing) {
                                    Button { session.attachments.removeAll { $0.id == a.id } } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain).offset(x: 4, y: -4)
                                }
                                .help(a.name)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            ZStack(alignment: .topLeading) {
                if session.input.isEmpty {
                    Text(placeholder).font(.system(size: 12.5)).foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                AIInputField(text: $session.input, height: $inputHeight, onSubmit: { session.send(); session.showHistory = false },
                             onPasteImage: { session.attach(image: $0) })
                    .frame(height: min(140, max(18, inputHeight)))
            }
            HStack(spacing: 8) {
                Button { pickImages() } label: { Image(systemName: "paperclip").font(.system(size: 12)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("附上图片（也可以直接粘贴截图）")
                Menu {
                    ForEach(skills.enabled) { s in
                        Button { session.pinnedSkill = s } label: { Text(s.name + "　" + String(s.description.prefix(28))) }
                    }
                    Divider()
                    Button("技能库…") { AISkillsWindow.show() }
                } label: {
                    Label("技能", systemImage: "sparkles").font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton).fixedSize()
                if session.running, let start = session.runStarted {
                    // Local models can take minutes; the elapsed time shows it is still working.
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        let secs = Int(ctx.date.timeIntervalSince(start))
                        Text(session.statusLine + (secs >= 3 ? " \(secs) 秒" : ""))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if session.running {
                    Button { session.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(AISendButtonStyle(enabled: true)).help("停止")
                } else {
                    Button { session.send(); session.showHistory = false } label: { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)) }
                        .buttonStyle(AISendButtonStyle(enabled: !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("发送（⏎；换行用 ⇧⏎）")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func pickImages() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image, .pdf]
        p.message = "选择要给 AI 看的图片"
        if p.runModal() == .OK { session.attach(files: p.urls) }
    }

    private var placeholder: String {
        if let f = tabs.current.file { return "让 AI 处理「\(f.name)」…" }
        return "让 AI 帮你做点事…"
    }
}

struct AISendButtonStyle: ButtonStyle {
    var enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(enabled ? Theme.ember : Color.secondary.opacity(0.35)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Multi-line input: ⏎ sends, ⇧⏎ (or ⌥⏎) adds a line.
struct AIInputField: NSViewRepresentable {
    @Binding var text: String
    /// The text's height, so the field grows with what is typed.
    @Binding var height: CGFloat
    var onSubmit: () -> Void
    /// A picture was pasted (screenshots go to the AI, not into the text).
    var onPasteImage: (NSImage) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SubmitTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 12.5)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onPasteImage = onPasteImage
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let sv = NSScrollView()
        sv.documentView = tv
        // Grows with the text up to a few lines, then scrolls (wheel / trackpad) without a bar.
        sv.hasVerticalScroller = false
        sv.drawsBackground = false
        sv.borderType = .noBorder
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? SubmitTextView else { return }
        tv.onSubmit = onSubmit
        if tv.string != text {
            tv.string = text
            context.coordinator.measure(tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIInputField
        init(_ p: AIInputField) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            measure(tv)
        }

        func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            if abs(h - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }

    final class SubmitTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onPasteImage: ((NSImage) -> Void)?

        override func paste(_ sender: Any?) {
            let pb = NSPasteboard.general
            // A copied picture (not a file) or a copied image file becomes an attachment.
            if !pb.canReadObject(forClasses: [NSString.self], options: nil) || pb.availableType(from: [.fileURL]) != nil,
               let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
                images.forEach { onPasteImage?($0) }
                return
            }
            super.paste(sender)
        }
        override func keyDown(with e: NSEvent) {
            let isReturn = e.keyCode == 36 || e.keyCode == 76
            if isReturn && e.modifierFlags.intersection([.shift, .option]).isEmpty && !hasMarkedText() {
                onSubmit?()
                return
            }
            super.keyDown(with: e)
        }
    }
}

/// Models offered by the current endpoint (local server or cloud provider).
@MainActor
final class AIModelList: ObservableObject {
    @Published var models: [String] = []
    @Published var loading = false
    @Published var error: String?

    func refresh() {
        let config = AIConfig.shared
        loading = true
        error = nil
        Task {
            defer { loading = false }
            switch config.mode {
            case .local:
                if let found = await config.detectLocal() {
                    if config.localBaseURL != found.base { config.localBaseURL = found.base }
                    models = found.models
                    if !found.models.contains(config.localModel) { config.localModel = Self.preferred(found.models) }
                } else {
                    models = []
                    error = "没找到本地模型：请打开 LM Studio 或 Ollama"
                }
            case .cloud:
                let p = config.provider
                guard let key = config.apiKey(p), let u = URL(string: config.cloudBaseURL(p)), u.host != nil else { models = []; return }
                do {
                    let list = try await AIClients.listModels(AIEndpoint(proto: p.proto, baseURL: u, model: config.cloudModel(p), apiKey: key))
                    models = list.sorted()
                } catch {
                    models = []
                    self.error = (error as? AIError)?.message ?? error.localizedDescription
                }
            }
        }
    }

    /// The biggest general chat model among local ones (skips vision / coder-only names when possible).
    static func preferred(_ list: [String]) -> String {
        func size(_ m: String) -> Double {
            let l = m.lowercased()
            guard let r = l.range(of: #"(\d+(\.\d+)?)b"#, options: .regularExpression) else { return 0 }
            return Double(l[r].dropLast()) ?? 0
        }
        return list.max { size($0) < size($1) } ?? list.first ?? ""
    }
}
