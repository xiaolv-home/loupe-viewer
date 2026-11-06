import AppKit
import SwiftUI
import ImageIO
import IOSurface
import CoreVideo
import UniformTypeIdentifiers
import LoupeCore

/// Clip view that keeps a smaller document centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let df = doc.frame
        if r.width > df.width { r.origin.x = df.midX - r.width / 2 }
        if r.height > df.height { r.origin.y = df.midY - r.height / 2 }
        return r
    }
}

/// Layer-backed bitmap surface. 1 point of this view = 1 image pixel / backing scale,
/// so magnification 1.0 shows true pixels on any display.
final class ImageSurface: NSView {
    var onDoubleClick: ((NSPoint) -> Void)?
    private var dragOrigin: NSPoint?
    /// The bitmap lives in a plain sublayer so it can be detached explicitly; Core Animation
    /// otherwise keeps a view's backing-layer contents alive after the view is gone.
    let imageLayer = CALayer()
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func setImage(_ img: Any?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = img
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func detach() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        imageLayer.removeFromSuperlayer()
        CATransaction.commit()
        CATransaction.flush()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .openHand) }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onDoubleClick?(convert(e.locationInWindow, from: nil)); return }
        dragOrigin = e.locationInWindow
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with e: NSEvent) {
        guard let o = dragOrigin, let clip = enclosingScrollView?.contentView else { return }
        let p = e.locationInWindow
        let mag = enclosingScrollView?.magnification ?? 1
        var b = clip.bounds.origin
        b.x -= (p.x - o.x) / mag
        b.y += (p.y - o.y) / mag
        clip.scroll(to: b)
        enclosingScrollView?.reflectScrolledClipView(clip)
        dragOrigin = p
    }
    override func mouseUp(with e: NSEvent) {
        if dragOrigin != nil { NSCursor.pop() }
        dragOrigin = nil
    }
}

/// Scroll view where a mouse wheel zooms around the pointer; trackpads keep panning.
final class ZoomScrollView: NSScrollView {
    var onMagnify: (() -> Void)?
    override func scrollWheel(with e: NSEvent) {
        let wantsZoom = !e.hasPreciseScrollingDeltas || e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option)
        guard wantsZoom, let doc = documentView else { super.scrollWheel(with: e); return }
        let delta = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
        guard delta != 0 else { return }
        let target = max(minMagnification, min(maxMagnification, magnification * (1 + delta)))
        setMagnification(target, centeredAt: doc.convert(e.locationInWindow, from: nil))
        onMagnify?()
    }
    override func magnify(with e: NSEvent) {
        super.magnify(with: e)
        onMagnify?()
    }
    override func endGesture(with e: NSEvent) {
        super.endGesture(with: e)
        onMagnify?()
    }
}
