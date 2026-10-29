import AppKit
import SwiftUI
import Quartz
import PDFKit
import CryptoKit
import LoupeCore

/// Word / Excel / PowerPoint / RTF via Quick Look. Presentations can be played full screen
/// after a background conversion through Keynote.
@MainActor
final class OfficeRenderer: Renderer, ObservableObject {
    static let engineName = "QuickLook"
    static func canHandle(_ file: FileContext) -> Bool { file.format.family == .office }

    private let ql = QuickLookRenderer()
    private var file: FileContext?
    private weak var host: RenderHost?
    @Published var converting = false

    required init() {}

    var isPresentation: Bool {
        guard let f = file else { return false }
        return ["ppt", "pptx", "pptm", "pps", "ppsx", "odp", "key"].contains(f.ext) || f.format.token == "PPTX" || f.format.token == "PPT"
    }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        self.host = host
        return try await ql.makeView(for: file, host: host)
    }

    func cleanup() { ql.cleanup() }

    func playSlideshow() {
        guard let file, let host, !converting else { return }
        guard DocumentExporter.appURL(.keynote) != nil else {
            // No Keynote: still give a full-screen view, using Quick Look's own rendering.
            SlideshowController.presentQuickLook(url: file.url, from: host.window)
            return
        }
        if let cached = DocumentExporter.cached(file.url), let doc = PDFDocument(url: cached) {
            SlideshowController.present(document: doc, startAt: 0, from: host.window)
            return
        }
        converting = true
        host.showNotice("正在用 Keynote 准备放映…（首次可能需要几秒，并会请求「自动化」权限）", style: .info, action: nil)
        Task { [weak self] in
            defer { self?.converting = false }
            do {
                let pdf = try await DocumentExporter.export(file.url, with: .keynote)
                guard let doc = PDFDocument(url: pdf), doc.pageCount > 0 else { throw ExportError.failed("转换结果无法读取") }
                self?.host?.notice = nil
                SlideshowController.present(document: doc, startAt: 0, from: self?.host?.window)
            } catch ExportError.notAuthorized {
                Log.write("slideshow: automation not authorized")
                self?.host?.showNotice("需要允许 Loupe 控制 Keynote 才能放映（系统设置 › 隐私与安全性 › 自动化）。也可以先用快速查看全屏浏览。", style: .warning,
                                       action: NoticeAction(title: "打开设置") { DocumentExporter.openAutomationSettings() })
            } catch {
                Log.write("slideshow failed: \(error)")
                self?.host?.showNotice("Keynote 转换失败，已改用快速查看全屏浏览：\(error.localizedDescription)", style: .warning, action: nil)
                SlideshowController.presentQuickLook(url: file.url, from: self?.host?.window)
            }
        }
    }

    var presentation: StagePresentation { .bleed }
    var statusText: String { "系统快速查看" + (isPresentation ? " · ⌥⌘P 全屏放映" : "") }
    var controls: AnyView? { isPresentation ? AnyView(OfficeControls(r: self)) : nil }
    var controlsPlacement: ControlsPlacement { .floating }
    func supports(_ c: ViewerCommand) -> Bool { c == .slideshow && isPresentation }
    func perform(_ c: ViewerCommand) { if c == .slideshow { playSlideshow() } }
}

private struct OfficeControls: View {
    @ObservedObject var r: OfficeRenderer
    var body: some View {
        Button { r.playSlideshow() } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 10))
                Text(r.converting ? "正在准备…" : "全屏放映").font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(Theme.ember)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(r.converting)
    }
}
