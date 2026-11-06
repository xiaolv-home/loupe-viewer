import AppKit
import SwiftUI
import OpenGL.GL3
import LoupeCore

/// One libmpv instance. Events are drained on a private queue and forwarded to the model on main.
final class MPVPlayer: @unchecked Sendable {
    let api: MPVLibrary.API
    private(set) var handle: OpaquePointer?
    private(set) var renderContext: OpaquePointer?
    private let queue = DispatchQueue(label: "loupe.mpv.events")
    weak var layer: MPVGLLayer?
    var onEvent: ((String, Any?) -> Void)?
    var onEndFile: ((Bool) -> Void)?
    var onLoaded: (() -> Void)?
    var onRenderFailure: (() -> Void)?
    private var destroyed = false

    init?(api: MPVLibrary.API) {
        self.api = api
        guard let h = api.create() else { return nil }
        handle = h
        let opts: [(String, String)] = [
            ("vo", "libmpv"), ("hwdec", "auto-safe"), ("keep-open", "yes"), ("idle", "yes"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("osc", "no"), ("terminal", "no"),
            ("config", "no"), ("load-scripts", "no"), ("ytdl", "no"), ("audio-display", "no"),
            ("sub-auto", "fuzzy"), ("sub-font-size", "44"), ("sub-border-size", "2.5"), ("sub-codepage", "auto"),
            ("screenshot-format", "png"), ("demuxer-max-bytes", "150MiB"), ("cache", "no"),
            // Picture quality: mpv's own high-quality preset (sharpest scaler, HDR tone mapping
            // that measures each frame's real peak) — no debanding, which would soften detail.
            ("profile", "high-quality"),
            // The picture is drawn in Display P3 with the sRGB curve, the space the layer is
            // tagged with (MPVGLLayer), so macOS colour-manages it like any other app's video.
            ("target-prim", "display-p3"), ("target-trc", "srgb")
        ]
        for (k, v) in opts { _ = api.setOption(h, k, v) }
        guard api.initialize(h) >= 0 else { api.terminateDestroy(h); return nil }
        for (i, name) in ["time-pos", "duration", "pause", "volume", "speed", "eof-reached"].enumerated() {
            let fmt = (name == "pause" || name == "eof-reached") ? MPVConst.formatFlag : MPVConst.formatDouble
            _ = api.observe(h, UInt64(i + 1), name, fmt)
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        api.setWakeup(h, { ctx in
            guard let ctx else { return }
            let me = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            me.queue.async { me.drain() }
        }, ctx)
    }

    func createRenderContext() {
        guard renderContext == nil, let h = handle, let ctx = layer?.cglContext else { return }
        CGLSetCurrentContext(ctx)
        var initParams = mpv_opengl_init_params(get_proc_address: getProcAddress, get_proc_address_ctx: nil)
        let apiType = strdup("opengl")
        defer { free(apiType) }
        var rc: OpaquePointer?
        let r: Int32 = withUnsafeMutablePointer(to: &initParams) { ip in
            var params = [mpv_render_param(type: MPVConst.rpAPIType, data: UnsafeMutableRawPointer(apiType)),
                          mpv_render_param(type: MPVConst.rpGLInit, data: UnsafeMutableRawPointer(ip)),
                          mpv_render_param(type: MPVConst.rpInvalid, data: nil)]
            return params.withUnsafeMutableBufferPointer { api.rcCreate(&rc, h, UnsafeMutableRawPointer($0.baseAddress!)) }
        }
        guard r >= 0, let rc else { return }
        renderContext = rc
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        api.rcSetUpdate(rc, { ctx in
            guard let ctx else { return }
            let me = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.layer?.setNeedsDisplay() }
        }, selfPtr)
    }

    func command(_ args: [String]) {
        guard let h = handle else { return }
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        _ = cargs.withUnsafeMutableBufferPointer { api.command(h, $0.baseAddress!) }
    }

    func set(_ name: String, double v: Double) {
        guard let h = handle else { return }
        var x = v
        _ = api.setProperty(h, name, MPVConst.formatDouble, &x)
    }

    func set(_ name: String, flag: Bool) {
        guard let h = handle else { return }
        var x: Int32 = flag ? 1 : 0
        _ = api.setProperty(h, name, MPVConst.formatFlag, &x)
    }

    func string(_ name: String) -> String? {
        guard let h = handle, let p = api.getPropertyString(h, name) else { return nil }
        defer { api.free(p) }
        return String(cString: p)
    }

    private func drain() {
        while let h = handle, !destroyed, let raw = api.waitEvent(h, 0) {
            let ev = raw.assumingMemoryBound(to: mpv_event.self)
            let id = ev.pointee.event_id
            if id == 0 { break }
            switch id {
            case MPVConst.evShutdown: return
            case MPVConst.evPropertyChange:
                guard let d = ev.pointee.data else { continue }
                let p = d.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let n = p.name.map({ String(cString: $0) }) else { continue }
                var value: Any?
                if let data = p.data {
                    if p.format == MPVConst.formatDouble { value = data.assumingMemoryBound(to: Double.self).pointee }
                    else if p.format == MPVConst.formatFlag { value = data.assumingMemoryBound(to: Int32.self).pointee != 0 }
                }
                DispatchQueue.main.async { self.onEvent?(n, value) }
            case MPVConst.evVideoReconfig:
                DispatchQueue.main.async { self.onEvent?("video-reconfig", nil) }
            case MPVConst.evFileLoaded:
                DispatchQueue.main.async { self.onLoaded?() }
            case MPVConst.evEndFile:
                var failed = false
                if let d = ev.pointee.data {
                    let e = d.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    failed = e.reason == MPVConst.endReasonError
                }
                DispatchQueue.main.async { self.onEndFile?(failed) }
            default: break
            }
        }
    }

    /// Frees the render context (with the GL context current) before destroying mpv.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        if let h = handle { api.setWakeup(h, nil, nil) }
        if let rc = renderContext {
            api.rcSetUpdate(rc, nil, nil)
            if let ctx = layer?.cglContext { CGLSetCurrentContext(ctx) }
            api.rcFree(rc)
            renderContext = nil
        }
        let h = handle
        handle = nil
        let api = self.api
        queue.async { if let h { api.terminateDestroy(h) } }
    }
}

// MARK: - Renderer
