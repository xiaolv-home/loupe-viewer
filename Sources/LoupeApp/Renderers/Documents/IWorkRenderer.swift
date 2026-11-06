import AppKit
import SwiftUI
import Quartz
import PDFKit
import CryptoKit
import LoupeCore

/// Pages / Keynote / Numbers. Quick Look first, then (if the app is installed) a full PDF
/// rendition exported in the background; without the app, the embedded preview image.
@MainActor
final class IWorkRenderer: Renderer {
    static let engineName = "iWork"
    static func canHandle(_ file: FileContext) -> Bool { true }

    private let swap = SwapView()
    private var ql: QuickLookRenderer?
    private var pdf: PDFRenderer?
    private var exportTask: Task<Void, Never>?
    private weak var host: RenderHost?
    private var kind: IWorkKind = .pages
    private var stage = "Quick Look"
    private var file: FileContext?

    required init() {}

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        self.file = file
        kind = file.format.iwork ?? .pages
        let installed = DocumentExporter.appURL(kind) != nil

        if installed, AppSettings.shared.iworkExport, let cached = DocumentExporter.cached(file.url), let doc = PDFDocument(url: cached) {
            showPDF(doc)
            return swap
        }
        if installed && AppSettings.shared.iworkExport {
            let q = QuickLookRenderer()
            ql = q
            swap.show(try await q.makeView(for: file, host: host))
            startExport()
        } else if let img = await Task.detached(operation: { DocumentExporter.embeddedPreview(file.url, isDirectory: file.isDirectory) }).value {
            stage = "内嵌预览图"
            let iv = NSImageView(image: img)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            let pad = NSView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            pad.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 24), iv.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -24),
                iv.topAnchor.constraint(equalTo: pad.topAnchor, constant: 24), iv.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -24)
            ])
            swap.show(pad)
            host.showNotice(installed ? "只显示了文稿内嵌的预览图。在设置中开启「iWork 完整预览」可查看全部页面。"
                                      : "只显示了文稿内嵌的预览图。安装 \(kind.appName) 后可完整预览全部页面。", style: .info, action: nil)
        } else {
            let q = QuickLookRenderer()
            ql = q
            swap.show(try await q.makeView(for: file, host: host))
        }
        return swap
    }

    private func startExport() {
        guard let file else { return }
        stage = "Quick Look · 正在生成完整预览"
        host?.showNotice("正在通过 \(kind.appName) 在后台生成完整预览…", style: .info, action: nil)
        let kind = self.kind
        exportTask = Task { [weak self] in
            do {
                let pdfURL = try await DocumentExporter.export(file.url, with: kind)
                guard let self, !Task.isCancelled, let doc = PDFDocument(url: pdfURL) else { return }
                self.showPDF(doc)
                self.host?.showNotice("已通过 \(kind.appName) 生成完整预览（共 \(doc.pageCount) 页）", style: .success, action: nil)
            } catch is CancellationError {
            } catch ExportError.notAuthorized {
                self?.stage = "Quick Look"
                self?.host?.showNotice("需要允许 Loupe 控制 \(kind.appName) 才能显示完整内容（系统设置 › 隐私与安全性 › 自动化）。",
                                       style: .warning, action: NoticeAction(title: "打开设置") { DocumentExporter.openAutomationSettings() })
                self?.host?.rendererDidUpdate()
            } catch {
                self?.stage = "Quick Look"
                self?.host?.showNotice("完整预览生成失败，继续使用快速查看：\(error.localizedDescription)", style: .warning, action: nil)
                self?.host?.rendererDidUpdate()
            }
        }
    }

    private func showPDF(_ doc: PDFDocument) {
        guard let host else { return }
        let p = PDFRenderer()
        p.derivedFrom = "由 \(kind.appName) 导出（已缓存）"
        let v = p.makeView(document: doc, host: host)
        pdf = p
        stage = "PDF（\(kind.appName) 导出）"
        swap.show(v)
        ql?.cleanup()
        ql = nil
        host.rendererDidUpdate()
    }

    func cleanup() {
        exportTask?.cancel()
        ql?.cleanup()
        pdf?.cleanup()
    }

    var presentation: StagePresentation { .bleed }
    var controls: AnyView? { pdf?.controls }
    var controlsPlacement: ControlsPlacement { pdf == nil ? .none : .floating }
    var statusText: String { pdf.map { $0.statusText + " · " + stage } ?? stage }
    var infoSections: [InfoSection] {
        var s = [InfoSection("iWork", [InfoItem("应用", kind.appName),
                                       InfoItem("本机已安装", DocumentExporter.appURL(kind) != nil ? "是" : "否"),
                                       InfoItem("显示方式", stage)])]
        s += pdf?.infoSections ?? []
        return s
    }
    func supports(_ c: ViewerCommand) -> Bool { pdf?.supports(c) ?? false }
    func perform(_ c: ViewerCommand) { pdf?.perform(c) }
    var initialFirstResponder: NSView? { pdf?.pdfView }
}
