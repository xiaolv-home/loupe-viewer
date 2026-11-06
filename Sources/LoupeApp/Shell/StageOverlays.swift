import SwiftUI
import AppKit
import LoupeCore

/// The slug line: like the information printed outside the trim of a proof —
/// registration mark, job details in spaced small type, and a colour bar.
struct StatusStrip: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        HStack(spacing: 0) {
            RegistrationMark(size: 11)
                .padding(.trailing, 10)
            if let f = model.file {
                slug(f.format.label, strong: true)
                sep
                slug(Fmt.bytes(f.size))
                if !model.statusText.isEmpty {
                    sep
                    slug(model.statusText).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                if model.controlsPlacement == .strip, let c = model.controls {
                    c.padding(.trailing, 10)
                }
                if let i = model.siblingIndex, model.siblings.count > 1 {
                    slug("\(i + 1) / \(model.siblings.count)")
                        .monospacedDigit()
                        .help("同文件夹中的位置 · ← → 切换")
                    sep
                }
                if !model.engine.isEmpty {
                    slug(model.engine.uppercased()).help("当前渲染引擎")
                        .padding(.trailing, 10)
                }
                ColorBar(category: f.format.family.category)
            } else {
                slug("LOUPE · 览", strong: true)
                sep
                slug("就绪")
                Spacer()
                slug("⌘O 打开")
                sep
                slug("⌘/ 快捷键")
                    .padding(.trailing, 10)
                ColorBar(category: .other)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.stage))
    }

    private func slug(_ s: String, strong: Bool = false) -> Text {
        Text(s)
            .font(.system(size: 10, weight: strong ? .semibold : .regular))
            .tracking(0.9)
            .foregroundColor(strong ? .primary.opacity(0.75) : nil)
    }

    private var sep: some View {
        Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 0.75, height: 9).padding(.horizontal, 9)
    }
}

/// Floating capsule above the content for visual renderers (image, PDF).
struct FloatingLens: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        Group {
            if model.controlsPlacement == .floating, let c = model.controls, model.loading == nil {
                HStack(spacing: 2) { c }
                    .padding(.horizontal, 6)
                    .frame(height: 34)
                    .background(Capsule(style: .continuous).fill(.regularMaterial))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.controlsPlacement == .floating)
        .padding(20) // room for the shadow
        .padding(-20)
    }
}

struct BannerOverlay: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        Group {
            if let n = model.notice {
                HStack(spacing: 10) {
                    Image(systemName: icon(n.style)).foregroundStyle(color(n.style))
                        .font(.system(size: 12, weight: .semibold))
                    Text(n.text).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let a = n.action {
                        Button(a.title) { a.handler() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ember)
                    }
                    Button { withAnimation { model.notice = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color(n.style).opacity(0.35), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(n.id)
            }
        }
        .animation(.spring(duration: 0.3), value: model.notice?.id)
    }

    func icon(_ s: NoticeStyle) -> String {
        switch s { case .info: return "info.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .success: return "checkmark.circle.fill" }
    }
    func color(_ s: NoticeStyle) -> Color {
        switch s { case .info: return .accentColor; case .warning: return Theme.ember; case .success: return .green }
    }
}

/// Loading indicator: a 2pt progress rule across the top of the content plus a quiet
/// caption with a cancel action. Appears only if loading takes longer than 250 ms.
struct LoadingOverlay: View {
    @ObservedObject var model: ViewerModel
    @State private var visible = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let l = model.loading, visible {
                ProgressRule(fraction: l.fraction)
                    .frame(height: 2)
                HStack(spacing: 10) {
                    Text(l.label).font(.system(size: 11, weight: .medium)).tracking(0.5)
                    if let f = l.fraction {
                        Text("\(Int(f * 100))%").font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
                    }
                    Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 0.75, height: 10)
                    Button("取消") { model.cancelLoading() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ember)
                        .keyboardShortcut(.cancelAction)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.trailing, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: visible && model.loading != nil)
        .onChange(of: model.loading != nil) { _, isLoading in
            visible = false
            guard isLoading else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if model.loading != nil { visible = true }
            }
        }
    }
}

/// Thin ember rule. Determinate fills left to right; indeterminate runs a short segment.
struct ProgressRule: View {
    var fraction: Double?
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.08))
                if let f = fraction {
                    Rectangle().fill(Theme.ember)
                        .frame(width: g.size.width * CGFloat(max(0.02, min(1, f))))
                        .animation(.easeOut(duration: 0.2), value: f)
                } else {
                    Rectangle().fill(Theme.ember)
                        .frame(width: g.size.width * 0.22)
                        .offset(x: (g.size.width * 1.22) * phase - g.size.width * 0.22)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                }
            }
            .clipped()
        }
    }
}

/// Drop affordance over an open document: crop marks frame the whole stage in ember.
struct DropHighlight: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        ZStack {
            if model.isDropTargeted && model.file != nil {
                Rectangle().fill(Color(nsColor: Theme.stage).opacity(0.72))
                CropMarks(gap: 10, length: 36)
                    .stroke(Theme.ember, lineWidth: 1.5)
                    .padding(36)
                VStack(spacing: 8) {
                    RegistrationMark(size: 22, color: Theme.ember)
                    Text("松开以打开").font(.system(size: 13, weight: .semibold)).tracking(2)
                        .foregroundStyle(Theme.ember)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: model.isDropTargeted)
    }
}

/// Shown when every renderer in the chain failed.
struct FailureView: View {
    let file: FileContext
    let reasons: [String]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable().frame(width: 96, height: 96)
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 24)).foregroundStyle(.white, Theme.ember)
                    .offset(x: 38, y: 34)
            }
            VStack(spacing: 6) {
                Text("无法预览此文件").font(.system(size: 17, weight: .semibold))
                Text(file.name).font(Theme.mono(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(reasons, id: \.self) { r in
                        Text("· " + r).font(Theme.mono(11)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: 460, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
            HStack(spacing: 10) {
                Button("用默认应用打开") { NSWorkspace.shared.open(file.url) }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
