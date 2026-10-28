import AppKit
import SwiftUI
import Quartz
import PDFKit
import CryptoKit
import LoupeCore

/// Generic system Quick Look preview (Office, usdz, epub, …).
@MainActor
final class QuickLookRenderer: Renderer {
    static let engineName = "QuickLook"
    static func canHandle(_ file: FileContext) -> Bool { true }
    private var preview: QLPreviewView?

    required init() {}

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        guard let v = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), style: .normal) else {
            throw RenderError.unsupported("Quick Look 不可用")
        }
        v.shouldCloseWithWindow = false
        v.autostarts = true
        v.previewItem = file.url as NSURL
        preview = v
        return v
    }

    func cleanup() {
        preview?.previewItem = nil
        preview?.close()
        preview = nil
    }

    var presentation: StagePresentation { .bleed }
    var statusText: String { "系统快速查看" }
}
