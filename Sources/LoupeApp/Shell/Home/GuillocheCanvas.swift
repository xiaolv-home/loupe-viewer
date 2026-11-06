import AppKit
import Metal
import MetalKit
import SwiftUI

/// A value chasing a target like a critically damped spring, the motion of everything on the start
/// page's engraving. Kept apart from the view so that its coming to rest can be tested: the canvas
/// only draws while something here is moving.
struct SpringValue {
    var value: SIMD2<Float>
    var target: SIMD2<Float>
    var velocity = SIMD2<Float>(0, 0)

    init(_ start: SIMD2<Float>) {
        value = start
        target = start
    }

    /// How close counts as there, in the value's own units.
    func isSettled(within tolerance: Float) -> Bool {
        let gap = target - value
        return (gap * gap).sum() < tolerance * tolerance && (velocity * velocity).sum() < tolerance * tolerance
    }

    mutating func step(by dt: Float, stiffness: Float) {
        // Exact solution for critical damping, so a long frame cannot overshoot or blow up.
        let gap = value - target
        let decay = exp(-stiffness * dt)
        let carried = (velocity + gap * stiffness) * dt
        value = target + (gap + carried) * decay
        velocity = (velocity - carried * stiffness) * decay
    }

    mutating func settle() {
        value = target
        velocity = .zero
    }
}

/// Where the loupe sits for a canvas of a given size, in points from the top left.
struct GuillocheLayout: Equatable {
    let lensRadius: Float
    let lensRest: SIMD2<Float>
    /// The pointer only takes the loupe to the right of this, clear of the title and buttons.
    let reachStart: Float
    private let width: Float
    private let height: Float

    init(width: Float, height: Float, titleEnd: Float) {
        self.width = width
        self.height = height
        lensRadius = min(max(height * 0.165, 40), 62)
        let restX = max(width * 0.68, titleEnd + lensRadius + 40)
        lensRest = SIMD2(min(restX, width - lensRadius - 12), Self.ribbonCenter(atX: restX, width: width, height: height))
        reachStart = titleEnd + 30
    }

    /// The height of the middle of the band of lines. The shader's `curve` at its middle line, so that
    /// the loupe rests on the lines and has something to show.
    static func ribbonCenter(atX x: Float, width: Float, height: Float) -> Float {
        let turn = 2 * Float.pi, X = x / max(width, 1)
        return height * 0.52 + height * 0.24 * sin(turn * (0.70 * X + 0.06) + 1.25) + height * 0.11 * sin(turn * (1.62 * X + 0.34) - 1.9)
    }

    /// The loupe's position for a pointer, kept whole inside the canvas.
    func lensPosition(forPointer p: SIMD2<Float>) -> SIMD2<Float> {
        let margin = lensRadius + 10
        return SIMD2(min(max(p.x, reachStart), width - margin), min(max(p.y, margin), height - margin))
    }
}

/// The compiled shaders and the microprinted words, shared by every start page. The first request
/// does the work off the main thread.
@MainActor
private enum GuillochePipeline {
    struct States {
        let linePage: MTLRenderPipelineState
        let lineLens: MTLRenderPipelineState
        let lensUnder: MTLRenderPipelineState
        let lensOver: MTLRenderPipelineState
        let words: MTLTexture
    }

    static let device = MTLCreateSystemDefaultDevice()
    private(set) static var states: States?
    private static var waiting: [() -> Void] = []
    private static var started = false

    static func whenReady(_ action: @escaping () -> Void) {
        if states != nil { return action() }
        waiting.append(action)
        guard !started, let device else { return }
        started = true
        Task {
            do {
                let library = try await device.makeLibrary(source: GuillocheShader.source, options: nil)
                func state(_ vertex: String, _ fragment: String) async throws -> MTLRenderPipelineState {
                    let d = MTLRenderPipelineDescriptor()
                    d.vertexFunction = library.makeFunction(name: vertex)
                    d.fragmentFunction = library.makeFunction(name: fragment)
                    let c = d.colorAttachments[0]!
                    c.pixelFormat = .bgra8Unorm
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .one
                    c.sourceAlphaBlendFactor = .one
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    return try await device.makeRenderPipelineState(descriptor: d)
                }
                guard let words = MicroprintAtlas.make(device: device) else { return }
                states = States(
                    linePage: try await state("lineVertex", "linePage"),
                    lineLens: try await state("lineVertex", "lineLens"),
                    lensUnder: try await state("wholeVertex", "lensUnder"),
                    lensOver: try await state("wholeVertex", "lensOver"),
                    words: words)
            } catch {
                // The engraving is decoration: the page stands without it.
                NSLog("Loupe: start page shader did not compile: \(error)")
            }
            if states != nil { waiting.forEach { $0() } }
            waiting = []
        }
    }
}

/// The words the hairlines are made of, one long strip that repeats.
private enum MicroprintAtlas {
    static let text =
        "LOUPE 览  一个窗口，看清每一种文件  PDF · XLSX · DOCX · PPTX · KEY · NUMBERS  照片 RAW HEIC  视频 音频 MOV MP4 MKV  "
        + "MARKDOWN · CSV · JSON · SQL · PY · SWIFT  压缩包 ZIP 7Z TAR  字体 OTF TTF WOFF  离线可用  看得清，才算看过  "
    static let height = 44

    static func make(device: MTLDevice) -> MTLTexture? {
        let font = NSFont.systemFont(ofSize: 30, weight: .medium)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = min(Int(ceil(string.size().width)) + 1, device.supportsFamily(.apple3) ? 16384 : 8192)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            let shared = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = shared
            string.draw(at: NSPoint(x: 0, y: (CGFloat(height) - string.size().height) / 2))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard drew else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width)
        return texture
    }
}

/// Draws the engraving on demand. There is no running loop: a display link exists only while the
/// loupe or the lines are moving, and goes away until the pointer next moves.
final class GuillocheCanvasView: MTKView {
    private struct Uniforms {
        var frame: SIMD4<Float>
        var lens: SIMD4<Float>
        var motion: SIMD4<Float>
        var lines: SIMD4<Float>
    }

    private static let lineCount = 92
    private static let pageSegments = 340
    private static let lensSegments = 70
    private static let runInTime: Float = 1.5

    private let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lens = SpringValue(.zero)
    /// x: how far the lines spread for a dragged file; y: how much the loupe parts them.
    private var lines = SpringValue(.zero)
    private var following = false
    private var positioned = false
    private var ranIn: Float = 0
    private var lastFrame: CFTimeInterval = 0
    private var frames: CADisplayLink?
    private var queue: MTLCommandQueue?
    private var tracking: NSTrackingArea?

    /// Where the title and buttons end, in points; the lines and the loupe keep clear of them.
    var titleEnd: Float = 300 {
        didSet {
            guard titleEnd != oldValue else { return }
            if !following { lens.target = layoutNow.lensRest; lens.settle() }
            refresh()
        }
    }

    var isDropTargeted = false {
        didSet {
            guard isDropTargeted != oldValue else { return }
            lines.target.x = isDropTargeted ? 1 : 0
            wake()
        }
    }

    private var layoutNow: GuillocheLayout { GuillocheLayout(width: Float(bounds.width), height: Float(bounds.height), titleEnd: titleEnd) }

    init() {
        super.init(frame: .zero, device: GuillochePipeline.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        queue = device?.makeCommandQueue()
        GuillochePipeline.whenReady { [weak self] in self?.begin() }
    }
    required init(coder: NSCoder) { fatalError() }

    private func begin() {
        if reducedMotion { ranIn = Self.runInTime }
        wake()
        refresh()
    }

    // MARK: Input

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseEntered(with event: NSEvent) { pointerMoved(event) }
    override func mouseExited(with event: NSEvent) { pointerLeft() }

    private func pointerMoved(_ event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        follow(SIMD2(Float(at.x), Float(bounds.height - at.y)))
    }

    /// Sends the loupe towards a point, in points from the top left.
    func follow(_ point: SIMD2<Float>) {
        guard !reducedMotion else { return }
        let layout = layoutNow
        guard point.x >= layout.reachStart else { return pointerLeft() }
        following = true
        lens.target = layout.lensPosition(forPointer: point)
        lines.target.y = 1
        wake()
    }

    func pointerLeft() {
        following = false
        lens.target = layoutNow.lensRest
        lines.target.y = 0
        wake()
    }

    // MARK: Frames

    /// Starts making frames until everything has come to rest.
    private func wake() {
        guard GuillochePipeline.states != nil, !isHiddenOrHasHiddenAncestor, window != nil, frames == nil else { return }
        lastFrame = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        frames = link
    }

    private func sleep() {
        frames?.invalidate()
        frames = nil
    }

    #if DEBUG
        private(set) var framesDrawn = 0
    #endif

    @objc private func frame(_ link: CADisplayLink) {
        #if DEBUG
            framesDrawn += 1
        #endif
        let now = CACurrentMediaTime()
        advance(by: Float(min(now - lastFrame, 1.0 / 20)))
        lastFrame = now
        draw()
        if !isMoving { sleep() }
    }

    /// Redraws once, for changes that move nothing.
    private func refresh() {
        guard GuillochePipeline.states != nil, frames == nil, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        DispatchQueue.main.async { [weak self] in
            if self?.frames == nil, self?.window != nil { self?.draw() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? sleep() : wake()
    }
    override func viewDidHide() {
        super.viewDidHide()
        sleep()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        wake()
        refresh()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        let layout = layoutNow
        if !positioned {
            positioned = true
            lens = SpringValue(layout.lensRest)
        } else if !following {
            lens.target = layout.lensRest
            lens.settle()
        }
        refresh()
    }

    private var isMoving: Bool {
        ranIn < Self.runInTime || !lens.isSettled(within: 0.02) || !lines.isSettled(within: 0.0008)
    }

    private func advance(by dt: Float) {
        ranIn = min(ranIn + dt, Self.runInTime)
        lens.step(by: dt, stiffness: following ? 24 : 8)
        lines.step(by: dt, stiffness: 9)
    }

    /// Jumps past any motion in progress, so the automation can take a still.
    func finishMotion() {
        ranIn = Self.runInTime
        lens.settle()
        lines.settle()
        sleep()
        if window != nil { draw() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let queue, let pass = currentRenderPassDescriptor, let drawable = currentDrawable, let commands = queue.makeCommandBuffer() else { return }
        encode(into: pass, commands: commands)
        commands.present(drawable)
        commands.commit()
    }

    private func encode(into pass: MTLRenderPassDescriptor, commands: MTLCommandBuffer) {
        guard let states = GuillochePipeline.states, let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let layout = layoutNow
        let black = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let progress = ranIn / Self.runInTime
        let opening = 1 - pow(1 - progress, 3)
        let presence = max(0, min(1, (progress - 0.42) / 0.5))
        var u = Uniforms(
            frame: SIMD4(Float(bounds.width), Float(bounds.height), Float(window?.backingScaleFactor ?? 2), black ? 1 : 0),
            lens: SIMD4(lens.value.x, lens.value.y, layout.lensRadius, presence * presence * (3 - 2 * presence)),
            motion: SIMD4(opening, lines.value.y, lines.value.x, titleEnd),
            lines: SIMD4(Float(Self.lineCount), Float(Self.pageSegments), Float(Self.lensSegments), Float(states.words.width) / Float(states.words.height)))
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)

        func drawLines(_ state: MTLRenderPipelineState, mode: Int32, segments: Int) {
            var mode = mode
            encoder.setRenderPipelineState(state)
            encoder.setVertexBytes(&mode, length: MemoryLayout<Int32>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: (segments + 1) * 2, instanceCount: Self.lineCount)
        }
        func drawWhole(_ state: MTLRenderPipelineState) {
            encoder.setRenderPipelineState(state)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        drawLines(states.linePage, mode: 0, segments: Self.pageSegments)
        drawWhole(states.lensUnder)
        encoder.setFragmentTexture(states.words, index: 0)
        drawLines(states.lineLens, mode: 1, segments: Self.lensSegments)
        drawWhole(states.lensOver)
        encoder.endEncoding()
    }

    #if DEBUG
        /// A still of the canvas as a PNG, with its place in the window. A window that is covered gets
        /// no new frames on screen, so automated runs look at this rather than disturb the user.
        func writeStill(to url: URL) {
            guard let device, let queue, let commands = queue.makeCommandBuffer() else { return }
            let scale = window?.backingScaleFactor ?? 2
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            texture.usage = .renderTarget
            texture.storageMode = .shared
            guard let target = device.makeTexture(descriptor: texture) else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            encode(into: pass, commands: commands)
            commands.commit()
            commands.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            let image = bytes.withUnsafeMutableBytes { raw in
                CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: info)?.makeImage()
            }
            guard let image else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            print("CANVAS", convert(bounds, to: nil), "windowHeight", window?.contentView?.bounds.height ?? 0)
        }
    #endif
}

/// The canvas as a piece of the start page.
struct GuillocheCanvas: NSViewRepresentable {
    let isDropTargeted: Bool
    let titleEnd: CGFloat

    func makeNSView(context: Context) -> GuillocheCanvasView { GuillocheCanvasView() }
    func updateNSView(_ view: GuillocheCanvasView, context: Context) {
        view.isDropTargeted = isDropTargeted
        view.titleEnd = Float(titleEnd)
    }
}
