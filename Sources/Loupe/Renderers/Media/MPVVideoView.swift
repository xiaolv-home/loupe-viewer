import AppKit
import SwiftUI
import OpenGL.GL3
import os
import LoupeCore

final class MPVGLLayer: CAOpenGLLayer {
    weak var player: MPVPlayer?
    /// Created up front so mpv's render context exists before any file is loaded
    /// (vo=libmpv disables video if no render context is attached at start).
    private(set) var cglContext: CGLContextObj?
    private(set) var cglPixelFormat: CGLPixelFormatObj?
    /// rcRender failures are reported once. The draw runs on the CGL thread.
    private let renderFailureSent = OSAllocatedUnfairLock(initialState: false)

    override init() {
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        // Untagged GL output is taken as the display's own colours, which oversaturates video on
        // wide-gamut screens. mpv renders into Display P3 (see MPVPlayer); say so, and macOS
        // converts it for whatever screen the window is on.
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        let attempts: [[CGLPixelFormatAttribute]] = [
            [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue), kCGLPFAAccelerated,
             kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers, _CGLPixelFormatAttribute(rawValue: 0)],
            [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue), kCGLPFADoubleBuffer, _CGLPixelFormatAttribute(rawValue: 0)]
        ]
        for a in attempts {
            var pf: CGLPixelFormatObj?
            var n: GLint = 0
            if CGLChoosePixelFormat(a, &pf, &n) == kCGLNoError, let pf {
                var ctx: CGLContextObj?
                if CGLCreateContext(pf, nil, &ctx) == kCGLNoError, let ctx {
                    var swap: GLint = 1
                    CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
                    cglPixelFormat = pf
                    cglContext = ctx
                    break
                }
                CGLReleasePixelFormat(pf)
            }
        }
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let c = cglContext { CGLReleaseContext(c) }
        if let p = cglPixelFormat { CGLReleasePixelFormat(p) }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        if let pf = cglPixelFormat { return CGLRetainPixelFormat(pf) }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        if let c = cglContext { return CGLRetainContext(c) }
        return super.copyCGLContext(forPixelFormat: pf)
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        player?.renderContext != nil
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let player, let rc = player.renderContext, let api = MPVLibrary.load()?.api else { return }
        var fboID: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fboID)
        var vp = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &vp)
        var fbo = mpv_opengl_fbo(fbo: Int32(fboID), w: Int32(vp[2]), h: Int32(vp[3]), internal_format: 0)
        var flip: Int32 = 1
        var renderResult: Int32 = 0
        withUnsafeMutablePointer(to: &fbo) { fp in
            withUnsafeMutablePointer(to: &flip) { flp in
                var params = [mpv_render_param(type: MPVConst.rpFBO, data: UnsafeMutableRawPointer(fp)),
                              mpv_render_param(type: MPVConst.rpFlipY, data: UnsafeMutableRawPointer(flp)),
                              mpv_render_param(type: MPVConst.rpInvalid, data: nil)]
                let drawn: Int32 = params.withUnsafeMutableBufferPointer { buf in
                    api.rcRender(rc, UnsafeMutableRawPointer(buf.baseAddress!))
                }
                renderResult = drawn
            }
        }
        if renderResult < 0 {
            let shouldReport: Bool = renderFailureSent.withLock { sent in
                if sent { return false }
                sent = true
                return true
            }
            if shouldReport {
                let callback = player.onRenderFailure
                DispatchQueue.main.async {
                    callback?()
                }
            }
        }
        glFlush()
    }
}

final class MPVVideoView: NSView {
    let glLayer = MPVGLLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = glLayer
        glLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layerContentsRedrawPolicy = .duringViewResize
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}

// MARK: - Player
