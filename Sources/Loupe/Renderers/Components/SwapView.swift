import AppKit
import SwiftUI
import Quartz
import PDFKit
import CryptoKit
import LoupeCore

/// Swappable container: shows one child view at a time with a cross-fade.
final class SwapView: NSView {
    private(set) var child: NSView?
    func show(_ v: NSView) {
        let old = child
        child = v
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alphaValue = old == nil ? 1 : 0
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        guard let old else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            v.animator().alphaValue = 1
            old.animator().alphaValue = 0
        }, completionHandler: { old.removeFromSuperview() })
    }
}
