import AppKit
import Quartz
import WebKit

/// The system Quick Look preview of a document, with zoom. Quick Look renders Office
/// spreadsheets as a web page (1 pt = 1 CSS px) and offers no zoom of its own, so this reaches
/// the web view inside and scales it.
///
/// It scales with `magnification` (the whole page, like a pinch), not `pageZoom`: page zoom
/// re-lays out the page, and WebKit's minimum font size then keeps small text from shrinking
/// with its rows, so text spills over the neighbouring rows.
final class OriginalPreview: NSView {
    private let ql: QLPreviewView
    /// Scale for 100%: the same text size as Loupe's table view (11 pt → 12.65 pt).
    static let baseScale: CGFloat = 1.15
    /// The zoom the sheet was saved at in Excel (1 = 100%).
    let sheetZoom: CGFloat
    private weak var web: WKWebView?
    private var attempts = 0
    private var pending: CGFloat = 1

    init?(url: URL, sheetZoom: CGFloat) {
        guard let ql = QLPreviewView(frame: .zero, style: .normal) else { return nil }
        self.ql = ql
        self.sheetZoom = sheetZoom
        super.init(frame: .zero)
        ql.shouldCloseWithWindow = false
        ql.autoresizingMask = [.width, .height]
        addSubview(ql)
        ql.previewItem = url as NSURL
        findWebView()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        ql.frame = bounds
    }

    func close() { ql.close() }

    var focusView: NSView { web ?? ql }

    private var scaleAt100: CGFloat { Self.baseScale * sheetZoom }

    /// Current zoom relative to 100% — includes pinches made directly on the page.
    var zoom: CGFloat {
        get { web.map { $0.magnification / scaleAt100 } ?? pending }
        set {
            pending = max(0.25, min(4, newValue))
            apply()
        }
    }

    private func apply() {
        guard let web else { return }
        web.pageZoom = 1
        let target = scaleAt100 * pending
        guard abs(web.magnification - target) > 0.0001 else { return }
        // Zoom around the middle of what is on screen, so the view does not jump to a corner.
        web.setMagnification(target, centeredAt: NSPoint(x: web.bounds.midX, y: web.bounds.midY))
    }

    /// The web view appears only once Quick Look has loaded the document; look for it a few
    /// times, and apply the zoom again shortly after in case loading resets it.
    private func findWebView() {
        func find(_ v: NSView) -> WKWebView? {
            if let w = v as? WKWebView { return w }
            for s in v.subviews { if let w = find(s) { return w } }
            return nil
        }
        if let w = find(ql) {
            web = w
            w.allowsMagnification = true
            apply()
            for delay in [0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
            return
        }
        attempts += 1
        guard attempts < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.findWebView() }
    }

    /// Debug: run JavaScript in the preview page.
    func evaluate(_ js: String) async -> String {
        guard let web else { return "no web view" }
        let r = try? await web.evaluateJavaScript(js)
        return "\(r ?? "nil") pageZoom=\(web.pageZoom) magnification=\(web.magnification)"
    }
}
