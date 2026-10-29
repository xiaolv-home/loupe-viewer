import AppKit
import SwiftUI
import ImageIO
import IOSurface
import CoreVideo
import UniformTypeIdentifiers
import os
import LoupeCore

/// A decoded frame ready for display. SDR images live in an IOSurface that Core Animation
/// samples directly (no conversion, no lingering caches); HDR images stay a CGImage so their
/// extended range survives.
struct DecodedImage: @unchecked Sendable {
    var surface: IOSurface?
    var image: CGImage?
    var pixelSize: CGSize
    var isHDR: Bool
    var hasAlpha: Bool
    var colorSpaceName: String?
    var downsampled: Bool
    var contents: Any? { surface ?? image }
}

@MainActor
final class ImageRenderer: NSObject, Renderer, ObservableObject {
    static let engineName = "ImageIO"
    static let maxTexture = 16384
    static func canHandle(_ file: FileContext) -> Bool { file.format.family == .image }

    @Published var zoomPercent: Int = 100
    @Published var fitMode = true
    @Published var pixelated = false { didSet { surface.imageLayer.magnificationFilter = pixelated ? .nearest : .linear } }
    @Published var page = 0
    @Published var pageCount = 1

    private let scroll = ZoomScrollView()
    private let surface = ImageSurface()
    private var source: CGImageSource?
    private var decoded: DecodedImage?
    private var rotation = 0 // quarter turns clockwise
    private var props: [String: Any] = [:]
    private var animating = false
    private var isIconFamily = false
    /// ImageIO calls the animation block off the main thread. This flag is the only state that block reads.
    private let animationGate = OSAllocatedUnfairLock(initialState: false)
    private var frameObserver: NSObjectProtocol?
    private weak var host: RenderHost?
    private var file: FileContext?

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        self.host = host
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw RenderError.unreadable("ImageIO 无法识别此图像")
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0, CGImageSourceGetStatus(src) != .statusInvalidData else {
            throw RenderError.unreadable("图像数据损坏或格式不受支持")
        }
        source = src
        pageCount = count
        // Icon files hold several sizes; start with the largest.
        var start = 0
        if count > 1, let t = CGImageSourceGetType(src) as String?, t == UTType.ico.identifier || t == UTType.icns.identifier || t == "com.microsoft.cur" {
            isIconFamily = true
            var best = 0
            for i in 0..<count {
                let pp = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]) ?? [:]
                let a = ((pp[kCGImagePropertyPixelWidth as String] as? Int) ?? 0) * ((pp[kCGImagePropertyPixelHeight as String] as? Int) ?? 0)
                if a > best { best = a; start = i }
            }
            page = start
        }
        props = (CGImageSourceCopyPropertiesAtIndex(src, start, nil) as? [String: Any]) ?? [:]
        if file.size > 8 << 20 { host.reportProgress(nil, label: "正在解码图像…") }
        let d = try await decode(index: start)
        try Task.checkCancellation()
        decoded = d

        scroll.contentView = CenteringClipView()
        scroll.documentView = surface
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.01
        scroll.maxMagnification = 64
        scroll.onMagnify = { [weak self] in self?.magnificationChanged(userInitiated: true) }
        surface.onDoubleClick = { [weak self] p in self?.toggleZoom(at: p) }
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.fitMode == true { self?.fit() } }
        }
        scroll.postsFrameChangedNotifications = true

        apply(d)
        fitMode = !AppSettings.shared.imageStartsActualSize
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitMode ? self.fit() : self.actualSize()
        }
        if isAnimated(src, count: count) { startAnimation(file.url) }
        return scroll
    }

    /// Full-resolution decode with EXIF orientation (and the user's rotation) applied;
    /// HDR gain maps are requested when supported.
    private func decode(index: Int) async throws -> DecodedImage {
        guard let src = source else { throw RenderError.unreadable("无图像源") }
        let p = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
        let w = (p[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let h = (p[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        let maxSide = max(w, h)
        let limit = Self.maxTexture
        let turns = rotation
        let result: DecodedImage? = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            var opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: maxSide > 0 ? min(maxSide, limit) : limit
            ]
            opts[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
            var img = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
            if img == nil {
                opts.removeValue(forKey: kCGImageSourceDecodeRequest)
                img = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
            }
            if img == nil { img = CGImageSourceCreateImageAtIndex(src, index, nil) }
            guard let img else { return nil }
            let cs = img.colorSpace
            let hdr = cs.map { CGColorSpaceUsesITUR_2100TF($0) || CGColorSpaceUsesExtendedRange($0) } ?? false
            let alpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(img.alphaInfo)
            let name = (cs?.name as String?)?.replacingOccurrences(of: "kCGColorSpace", with: "")
            if !hdr, let surf = ImageRenderer.makeSurface(img, quarterTurns: turns) {
                return DecodedImage(surface: surf, image: nil, pixelSize: CGSize(width: surf.width, height: surf.height),
                                    isHDR: false, hasAlpha: alpha, colorSpaceName: name, downsampled: maxSide > limit)
            }
            let shown = turns == 0 ? img : (ImageRenderer.rotate(img, quarterTurns: turns) ?? img)
            return DecodedImage(surface: nil, image: shown, pixelSize: CGSize(width: shown.width, height: shown.height),
                                isHDR: hdr, hasAlpha: alpha, colorSpaceName: name, downsampled: maxSide > limit)
        }.value
        guard let result else { throw RenderError.unreadable("无法解码图像（文件可能已损坏）") }
        return result
    }

    private func apply(_ d: DecodedImage) {
        surface.setImage(d.contents)
        surface.imageLayer.wantsExtendedDynamicRangeContent = d.isHDR
        surface.imageLayer.backgroundColor = d.hasAlpha ? NSColor(patternImage: Self.checker).cgColor : nil
        let scale = scroll.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        surface.frame = NSRect(x: 0, y: 0, width: d.pixelSize.width / scale, height: d.pixelSize.height / scale)
        surface.needsLayout = true
    }

    /// Draws the image (optionally rotated) into a BGRA IOSurface tagged with its colour space.
    /// Core Animation displays such a surface as-is, and its memory goes away with the surface.
    nonisolated static func makeSurface(_ img: CGImage, quarterTurns q: Int) -> IOSurface? {
        let turns = ((q % 4) + 4) % 4
        let (w, h) = turns % 2 == 1 ? (img.height, img.width) : (img.width, img.height)
        guard w > 0, h > 0 else { return nil }
        let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)
        let props: [IOSurfacePropertyKey: Any] = [
            .width: w, .height: h, .bytesPerElement: 4, .bytesPerRow: bpr,
            .allocSize: bpr * h, .pixelFormat: kCVPixelFormatType_32BGRA
        ]
        guard let surf = IOSurface(properties: props) else { return nil }
        let cs: CGColorSpace
        if let c = img.colorSpace, c.model == .rgb { cs = c } else { cs = CGColorSpace(name: CGColorSpace.sRGB)! }
        surf.lock(options: [], seed: nil)
        defer { surf.unlock(options: [], seed: nil) }
        guard let ctx = CGContext(data: surf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: surf.bytesPerRow,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .none
        if turns != 0 {
            ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            ctx.rotate(by: -CGFloat(turns) * .pi / 2)
            ctx.translateBy(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        if let name = cs.name {
            IOSurfaceSetValue(unsafeBitCast(surf, to: IOSurfaceRef.self), kIOSurfaceColorSpace, name)
        } else if let icc = cs.copyICCData() {
            IOSurfaceSetValue(unsafeBitCast(surf, to: IOSurfaceRef.self), kIOSurfaceICCProfile, icc)
        }
        return surf
    }

    nonisolated static func rotate(_ img: CGImage, quarterTurns q: Int) -> CGImage? {
        let turns = ((q % 4) + 4) % 4
        guard turns != 0 else { return img }
        let w = img.width, h = img.height
        let (nw, nh) = turns % 2 == 1 ? (h, w) : (w, h)
        let wide = img.bitsPerComponent > 8
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: wide ? 16 : 8,
                                  bytesPerRow: 0, space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: wide ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                                                   : CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    static let checker: NSImage = {
        let s: CGFloat = 8
        return NSImage(size: NSSize(width: s * 2, height: s * 2), flipped: false) { r in
            NSColor(white: 0.5, alpha: 0.12).setFill()
            NSRect(x: 0, y: 0, width: s, height: s).fill()
            NSRect(x: s, y: s, width: s, height: s).fill()
            return true
        }
    }()

    private func isAnimated(_ src: CGImageSource, count: Int) -> Bool {
        guard count > 1, let type = CGImageSourceGetType(src) as String? else { return false }
        return [UTType.gif.identifier, UTType.png.identifier, UTType.webP.identifier, "public.heics"].contains(type)
    }

    private func setAnimationStopped(_ value: Bool) {
        animationGate.withLock { $0 = value }
    }

    private func startAnimation(_ url: URL) {
        animating = true
        setAnimationStopped(false)
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, image, stop in
            guard let self else { stop.pointee = true; return }
            let stopped = self.animationGate.withLock { $0 }
            if stopped { stop.pointee = true; return }
            guard let image else { return }
            let frame = image
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let stillStopped = self.animationGate.withLock { $0 }
                    if stillStopped || self.rotation != 0 { return }
                    self.surface.setImage(frame)
                }
            }
        }
    }

    // MARK: Zoom

    private func magnificationChanged(userInitiated: Bool) {
        if userInitiated { fitMode = false }
        zoomPercent = Int((scroll.magnification * 100).rounded())
        if !pixelated { surface.imageLayer.magnificationFilter = scroll.magnification >= 6 ? .nearest : .linear }
    }

    func fit() {
        let avail = scroll.contentView.bounds.size.applying(CGAffineTransform(scaleX: scroll.magnification, y: scroll.magnification))
        let size = surface.frame.size
        guard size.width > 0, size.height > 0, avail.width > 0 else { return }
        let m = min(1, min((scroll.frame.width - 48) / size.width, (scroll.frame.height - 48) / size.height))
        _ = avail
        scroll.magnification = max(scroll.minMagnification, m)
        fitMode = true
        magnificationChanged(userInitiated: false)
    }

    func actualSize() {
        scroll.setMagnification(1, centeredAt: NSPoint(x: surface.bounds.midX, y: surface.bounds.midY))
        fitMode = false
        magnificationChanged(userInitiated: false)
    }

    func zoom(_ factor: CGFloat) {
        let center = scroll.contentView.bounds
        scroll.setMagnification(max(scroll.minMagnification, min(scroll.maxMagnification, scroll.magnification * factor)),
                                centeredAt: NSPoint(x: center.midX, y: center.midY))
        fitMode = false
        magnificationChanged(userInitiated: false)
    }

    private func toggleZoom(at p: NSPoint) {
        if fitMode || scroll.magnification < 0.99 {
            scroll.setMagnification(1, centeredAt: p)
            fitMode = false
            magnificationChanged(userInitiated: false)
        } else {
            fit()
        }
    }

    func rotate(_ d: Int) {
        guard decoded != nil else { return }
        setAnimationStopped(true)
        rotation = (rotation + d + 4) % 4
        Task {
            guard let dec = try? await decode(index: page) else { return }
            decoded = dec
            apply(dec)
            fit()
            host?.rendererDidUpdate()
        }
    }

    func showPage(_ p: Int) {
        guard p >= 0, p < pageCount, p != page else { return }
        page = p
        Task {
            if let d = try? await decode(index: p) {
                decoded = d
                apply(d)
                fit()
                host?.rendererDidUpdate()
            }
        }
    }

    func cleanup() {
        setAnimationStopped(true)
        if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
        surface.detach()
        decoded = nil
        source = nil
    }

    // MARK: Renderer surface

    var presentation: StagePresentation { .bleed }
    var controlsPlacement: ControlsPlacement { .floating }
    var controls: AnyView? { AnyView(ImageControls(r: self)) }
    var initialFirstResponder: NSView? { surface }

    func supports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .zoomIn, .zoomOut, .actualSize, .zoomToFit, .rotateLeft, .rotateRight: return true
        default: return false
        }
    }

    func perform(_ c: ViewerCommand) {
        switch c {
        case .zoomIn: zoom(1.25)
        case .zoomOut: zoom(0.8)
        case .actualSize: actualSize()
        case .zoomToFit: fit()
        case .rotateLeft: rotate(-1)
        case .rotateRight: rotate(1)
        default: break
        }
    }

    var statusText: String {
        guard let d = decoded else { return "" }
        var parts = ["\(Int(d.pixelSize.width)) × \(Int(d.pixelSize.height)) px"]
        if let cs = colorSpaceName { parts.append(cs) }
        if d.isHDR { parts.append("HDR") }
        if pageCount > 1 { parts.append(animating ? "\(pageCount) 帧" : (isIconFamily ? "\(pageCount) 种尺寸" : "第 \(page + 1)/\(pageCount) 页")) }
        return parts.joined(separator: " · ")
    }

    private var colorSpaceName: String? {
        if let n = props[kCGImagePropertyProfileName as String] as? String { return n }
        if let n = decoded?.colorSpaceName { return n }
        return props[kCGImagePropertyColorModel as String] as? String
    }

    var infoSections: [InfoSection] {
        var img: [InfoItem] = []
        let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? Int(decoded?.pixelSize.width ?? 0)
        let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? Int(decoded?.pixelSize.height ?? 0)
        img.append(InfoItem("尺寸", "\(w) × \(h) 像素"))
        if w > 0 && h > 0 { img.append(InfoItem("像素数", String(format: "%.1f 百万", Double(w * h) / 1e6))) }
        if let cs = colorSpaceName { img.append(InfoItem("色彩配置", cs)) }
        if let m = props[kCGImagePropertyColorModel as String] as? String { img.append(InfoItem("色彩模型", m)) }
        if let depth = props[kCGImagePropertyDepth as String] as? Int { img.append(InfoItem("位深", "\(depth) 位/通道")) }
        if let a = props[kCGImagePropertyHasAlpha as String] as? Bool { img.append(InfoItem("透明通道", a ? "有" : "无")) }
        if let dpi = props[kCGImagePropertyDPIWidth as String] as? Double { img.append(InfoItem("分辨率", "\(Int(dpi)) DPI")) }
        if let o = props[kCGImagePropertyOrientation as String] as? Int, o != 1 { img.append(InfoItem("方向", "EXIF \(o)（已自动校正）")) }
        img.append(InfoItem("动态范围", decoded?.isHDR == true ? "HDR（扩展动态范围显示）" : "SDR"))
        if pageCount > 1 { img.append(InfoItem(animating ? "帧数" : "页数", "\(pageCount)")) }
        if decoded?.downsampled == true { img.append(InfoItem("显示", "超出 \(Self.maxTexture) 像素，已缩减显示")) }
        if let src = source, let t = CGImageSourceGetType(src) as String? { img.append(InfoItem("编码", UTType(t)?.localizedDescription ?? t)) }

        var sections = [InfoSection("图像", img)]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        var shot: [InfoItem] = []
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model { shot.append(InfoItem("相机", [make, model].compactMap { $0 }.joined(separator: " "))) }
        if let lens = exif[kCGImagePropertyExifLensModel as String] as? String { shot.append(InfoItem("镜头", lens)) }
        if let fl = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            var s = String(format: "%g mm", fl)
            if let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int { s += "（等效 \(f35) mm）" }
            shot.append(InfoItem("焦距", s))
        }
        if let fn = exif[kCGImagePropertyExifFNumber as String] as? Double { shot.append(InfoItem("光圈", String(format: "ƒ/%g", fn))) }
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            shot.append(InfoItem("快门", t >= 1 ? String(format: "%g 秒", t) : "1/\(Int((1 / t).rounded())) 秒"))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { shot.append(InfoItem("ISO", "\(iso)")) }
        if let eb = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double, eb != 0 { shot.append(InfoItem("曝光补偿", String(format: "%+.1f EV", eb))) }
        if let d = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String { shot.append(InfoItem("拍摄时间", d)) }
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double, let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let ns = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let ew = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            shot.append(InfoItem("位置", String(format: "%.5f°%@, %.5f°%@", lat, ns, lon, ew)))
        }
        if let sw = tiff[kCGImagePropertyTIFFSoftware as String] as? String { shot.append(InfoItem("软件", sw)) }
        if !shot.isEmpty { sections.append(InfoSection("拍摄参数（EXIF）", shot)) }
        return sections
    }
}

private struct ImageControls: View {
    @ObservedObject var r: ImageRenderer
    var body: some View {
        HStack(spacing: 2) {
            LensButton(symbol: "arrow.down.right.and.arrow.up.left", help: "适应窗口（⌘9）", active: r.fitMode) { r.fit() }
            Button { r.actualSize() } label: {
                Text("1:1").font(.system(size: 11, weight: .bold)).frame(width: 30, height: 24)
                    .foregroundStyle(!r.fitMode && r.zoomPercent == 100 ? Theme.ember : Color.primary.opacity(0.75))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("原始像素（⌘0）")
            LensDivider()
            LensButton(symbol: "minus", help: "缩小（⌘−）") { r.zoom(0.8) }
            Readout(text: "\(r.zoomPercent)%", minWidth: 46)
            LensButton(symbol: "plus", help: "放大（⌘+）") { r.zoom(1.25) }
            LensDivider()
            LensButton(symbol: "rotate.left", help: "向左旋转（⌘L）") { r.rotate(-1) }
            LensButton(symbol: "rotate.right", help: "向右旋转（⌘R）") { r.rotate(1) }
            LensButton(symbol: "squareshape.split.3x3", help: "像素化显示（放大时不插值）", active: r.pixelated) { r.pixelated.toggle() }
            if r.pageCount > 1 && !r.isAnimatedImage {
                LensDivider()
                LensButton(symbol: "chevron.left", help: "上一页", enabled: r.page > 0) { r.showPage(r.page - 1) }
                Readout(text: "\(r.page + 1)/\(r.pageCount)", minWidth: 36)
                LensButton(symbol: "chevron.right", help: "下一页", enabled: r.page < r.pageCount - 1) { r.showPage(r.page + 1) }
            }
        }
    }
}

extension ImageRenderer {
    var isAnimatedImage: Bool { animating }
}
