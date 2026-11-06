import AppKit
import SwiftUI
import LoupeCore

/// The proofing table behind everything: a flat neutral with a soft centre light.
final class StageBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.stage.setFill()
        dirtyRect.fill()
        // A faint pool of light in the middle, like a lamp over the table.
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let g = NSGradient(colors: [NSColor.white.withAlphaComponent(isDark ? 0.035 : 0.28), NSColor.white.withAlphaComponent(0)]) {
            g.draw(in: NSBezierPath(rect: bounds), relativeCenterPosition: NSPoint(x: 0, y: 0.15))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Paper sheet holding a document renderer, with printer's crop marks at the corners.
final class SheetFrameView: NSView {
    let paper = NSView()
    private let shadowView = NSView()
    private var insetConstraints: [NSLayoutConstraint] = []
    private let markLength: CGFloat = 13
    private let markGap: CGFloat = 5

    init(content: NSView) {
        super.init(frame: .zero)
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.16
        shadowView.layer?.shadowRadius = 14
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        paper.wantsLayer = true
        paper.layer?.cornerRadius = 3
        paper.layer?.masksToBounds = true
        paper.layer?.borderWidth = 0.5
        for v in [shadowView, paper] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            content.topAnchor.constraint(equalTo: paper.topAnchor),
            content.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            shadowView.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            shadowView.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            shadowView.topAnchor.constraint(equalTo: paper.topAnchor),
            shadowView.bottomAnchor.constraint(equalTo: paper.bottomAnchor)
        ])
        updateInsets()
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func margins() -> NSEdgeInsets {
        let side: CGFloat = bounds.width < 700 ? 18 : 30
        return NSEdgeInsets(top: 24, left: side, bottom: 22, right: side)
    }

    private func updateInsets() {
        NSLayoutConstraint.deactivate(insetConstraints)
        let m = margins()
        insetConstraints = [
            paper.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m.left),
            paper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m.right),
            paper.topAnchor.constraint(equalTo: topAnchor, constant: m.top),
            paper.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -m.bottom)
        ]
        NSLayoutConstraint.activate(insetConstraints)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasNarrow = bounds.width < 700
        super.setFrameSize(newSize)
        if (newSize.width < 700) != wasNarrow { updateInsets() }
        shadowView.layer?.shadowPath = CGPath(rect: shadowView.bounds, transform: nil)
        needsDisplay = true
    }

    private func updateColors() {
        shadowView.layer?.backgroundColor = Theme.sheet.cgColor
        paper.layer?.backgroundColor = Theme.sheet.cgColor
        paper.layer?.borderColor = Theme.hairline.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { updateColors() }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        shadowView.layer?.shadowPath = CGPath(rect: shadowView.bounds, transform: nil)
    }

    /// Crop marks: short hairlines extending each sheet edge out into the margin.
    override func draw(_ dirtyRect: NSRect) {
        let r = paper.frame
        guard r.width > 40, r.height > 40 else { return }
        Theme.cropMark.setStroke()
        let p = NSBezierPath()
        p.lineWidth = 0.75
        let g = markGap, l = markLength
        for (x, y, dx, dy) in [(r.minX, r.minY, -1.0, -1.0), (r.maxX, r.minY, 1.0, -1.0),
                               (r.minX, r.maxY, -1.0, 1.0), (r.maxX, r.maxY, 1.0, 1.0)] {
            // horizontal mark, offset from the corner along the edge line
            p.move(to: NSPoint(x: x + dx * g, y: y)); p.line(to: NSPoint(x: x + dx * (g + l), y: y))
            p.move(to: NSPoint(x: x, y: y + dy * g)); p.line(to: NSPoint(x: x, y: y + dy * (g + l)))
        }
        p.stroke()
        // Registration target centred in the top margin.
        let c = NSPoint(x: r.midX, y: r.minY / 2)
        if r.minY > 16 {
            let rr: CGFloat = 4
            let reg = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            reg.move(to: NSPoint(x: c.x - 8, y: c.y)); reg.line(to: NSPoint(x: c.x + 8, y: c.y))
            reg.move(to: NSPoint(x: c.x, y: c.y - 8)); reg.line(to: NSPoint(x: c.x, y: c.y + 8))
            reg.lineWidth = 0.75
            reg.stroke()
        }
    }
}

/// Root view of the stage; accepts file drops for the whole window.
final class StageDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onTargetChange: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onTargetChange?(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onTargetChange?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargetChange?(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(sender)
        onTargetChange?(false)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}

/// Hosting view that only reacts to clicks on actual SwiftUI content.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

@MainActor
final class StageViewController: NSViewController {
    let model: ViewerModel
    private let background = StageBackgroundView()
    private let content = NSView()
    private var rendererView: NSView?
    private var failureHost: NSView?
    private var emptyHost: NSView?
    private var stripHeight: NSLayoutConstraint?

    /// False for a tab that opens straight into a file: no home page flashing first.
    private let startsOnHome: Bool

    init(model: ViewerModel, startsOnHome: Bool = true) {
        self.model = model
        self.startsOnHome = startsOnHome
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = StageDropView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        root.onDrop = { [weak self] urls in
            guard let self else { return }
            AppDelegate.shared?.openURLs(urls, preferredWindow: self.model.windowController)
        }
        root.onTargetChange = { [weak self] t in self?.model.isDropTargeted = t }
        view = root

        for v in [background, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        content.wantsLayer = true

        let strip = NSHostingView(rootView: StatusStrip(model: model))
        strip.sizingOptions = []
        strip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(strip)

        let lens = PassthroughHostingView(rootView: FloatingLens(model: model))
        let banner = PassthroughHostingView(rootView: BannerOverlay(model: model))
        let loading = PassthroughHostingView(rootView: LoadingOverlay(model: model))
        let drop = PassthroughHostingView(rootView: DropHighlight(model: model))
        lens.sizingOptions = [.intrinsicContentSize]
        banner.sizingOptions = [.intrinsicContentSize]
        loading.sizingOptions = []
        drop.sizingOptions = []
        for v in [lens, banner, loading, drop] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: 28),

            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: strip.topAnchor),

            lens.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            lens.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            lens.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),

            banner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            banner.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            banner.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32),

            loading.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            loading.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            loading.topAnchor.constraint(equalTo: content.topAnchor),

            drop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            drop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            drop.topAnchor.constraint(equalTo: root.topAnchor),
            drop.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        if startsOnHome { showEmpty() }
    }

    private func pin(_ v: NSView, in container: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    /// Shows a renderer's view. The previous one stays underneath while the new one fades in,
    /// so moving between files never flashes an empty stage; `replaced` runs once it is gone.
    func install(_ v: NSView, presentation: StagePresentation, replaced: (() -> Void)? = nil) {
        // Whatever is showing now (a file, the home page, an error) stays until the new view is in.
        let transient = [emptyHost, failureHost].compactMap { $0 }
        emptyHost = nil
        failureHost = nil
        let old = rendererView ?? transient.first
        let host: NSView = presentation == .sheet ? SheetFrameView(content: v) : v
        rendererView = host
        pin(host, in: content)
        func finish() {
            old?.removeFromSuperview()
            transient.forEach { $0.removeFromSuperview() }
            replaced?()
        }
        // Nothing to blend from (a fresh tab): just appear. Otherwise a short crossfade over the
        // old view — and none at all when no one can see it (hidden windows never animate).
        guard old != nil, view.window?.occlusionState.contains(.visible) == true else { finish(); return }
        host.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            host.animator().alphaValue = 1
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }

    func clear() {
        rendererView?.removeFromSuperview()
        rendererView = nil
        removeTransient()
    }

    private func removeTransient() {
        failureHost?.removeFromSuperview(); failureHost = nil
        emptyHost?.removeFromSuperview(); emptyHost = nil
    }

    func showEmpty() {
        clear()
        let host = NSHostingView(rootView: EmptyStateView(model: model))
        host.sizingOptions = []
        emptyHost = host
        pin(host, in: content)
    }

    func showFailure(file: FileContext, reasons: [String]) {
        clear()
        let host = NSHostingView(rootView: FailureView(file: file, reasons: reasons))
        host.sizingOptions = []
        failureHost = host
        pin(host, in: content)
    }
}
