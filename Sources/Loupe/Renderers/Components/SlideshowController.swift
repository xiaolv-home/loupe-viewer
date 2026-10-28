import AppKit
import SwiftUI
import PDFKit
import LoupeCore
import LoupeObjC
import Quartz

/// Full-screen presentation of PDF pages (used for PDFs and exported Keynote/PowerPoint decks).
@MainActor
final class SlideshowController: NSObject {
    private static var current: SlideshowController?
    private var window: NSWindow?
    private let view = SlideView()
    private var quickLook: QLPreviewView?

    /// Borderless windows refuse key status by default, which would leave the
    /// slideshow deaf to ←/→ and Esc.
    final class SlideWindow: NSWindow {
        var onKey: ((NSEvent) -> Bool)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
        override func cancelOperation(_ sender: Any?) { _ = onKey?(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!) }
    }

    final class SlideView: PDFView {
        var onKey: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
        override func mouseDown(with e: NSEvent) { _ = onKey?(e) }
    }

    static func present(document: PDFDocument, startAt: Int, from parent: NSWindow?) {
        current?.close()
        let c = SlideshowController()
        current = c
        c.show(document, startAt: startAt, screen: parent?.screen ?? NSScreen.main)
    }

    /// Fallback without Keynote: Quick Look's rendering, full screen, Esc to leave.
    static func presentQuickLook(url: URL, from parent: NSWindow?) {
        current?.close()
        let c = SlideshowController()
        current = c
        guard let screen = parent?.screen ?? NSScreen.main,
              let ql = QLPreviewView(frame: screen.frame, style: .normal) else { return }
        ql.previewItem = url as NSURL
        c.quickLook = ql
        let w = SlideWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentView = ql
        w.onKey = { [weak c] e in
            guard e.keyCode == 53 else { return false }
            c?.close(); return true
        }
        c.window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func show(_ doc: PDFDocument, startAt: Int, screen: NSScreen?) {
        guard let screen else { return }
        let w = SlideWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        view.document = doc
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .black
        view.pageShadowsEnabled = false
        if let p = doc.page(at: startAt) { view.go(to: p) }
        view.onKey = { [weak self] e in self?.handle(e) ?? false }
        w.onKey = { [weak self] e in self?.handle(e) ?? false }
        w.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSCursor.setHiddenUntilMouseMoves(true)
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Log.write("slideshow shown: \(doc.pageCount) pages, key=\(w.isKeyWindow), app active=\(NSApp.isActive)")
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        if e.type == .leftMouseDown { view.goToNextPage(nil); return true }
        switch e.keyCode {
        case 53: close(); return true                              // esc
        case 124, 125, 49, 121, 36: view.goToNextPage(nil); return true // → ↓ space pgdn return
        case 123, 126, 116, 51: view.goToPreviousPage(nil); return true  // ← ↑ pgup delete
        case 115: view.goToFirstPage(nil); return true
        case 119: view.goToLastPage(nil); return true
        default: return false
        }
    }

    func close() {
        window?.orderOut(nil)
        quickLook?.close()
        quickLook = nil
        view.document = nil
        window = nil
        SlideshowController.current = nil
    }
}
