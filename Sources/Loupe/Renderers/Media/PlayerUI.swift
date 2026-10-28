import AppKit
import SwiftUI
import LoupeCore

/// Engine-independent playback state + actions, shared by AVFoundation and mpv.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1
    @Published var muted = false
    @Published var rate: Double = 1
    @Published var hasVideo = true
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage?
    @Published var subtitleText: String?
    @Published var subtitleOptions: [String] = []
    @Published var selectedSubtitle = -1
    @Published var canPiP = false
    @Published var controlsVisible = true
    @Published var engineLabel = ""
    @Published var videoInfo = ""

    var onPlayPause: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    var onVolume: (Double) -> Void = { _ in }
    var onMute: (Bool) -> Void = { _ in }
    var onRate: (Double) -> Void = { _ in }
    var onSnapshot: () -> Void = {}
    var onPiP: () -> Void = {}
    var onSelectSubtitle: (Int) -> Void = { _ in }
    var onLoadSubtitle: (URL) -> Void = { _ in }
    weak var window: NSWindow?

    func toggleFullscreen() { window?.toggleFullScreen(nil) }

    func chooseSubtitleFile(near url: URL?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = []
        p.allowsOtherFileTypes = true
        p.directoryURL = url?.deletingLastPathComponent()
        p.message = "选择字幕文件（SRT / VTT / ASS）"
        if p.runModal() == .OK, let u = p.url { onLoadSubtitle(u) }
    }
}

/// Container for video/audio: owns the engine view, subtitle overlay and auto-hiding controls.
final class MediaStageView: NSView {
    let model: PlayerModel
    private var hideTimer: Timer?
    private var tracking: NSTrackingArea?
    var fileURL: URL?

    init(model: PlayerModel, videoView: NSView) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let overlay = NSHostingView(rootView: MediaOverlay(model: model, fileURL: { [weak self] in self?.fileURL }))
        overlay.sizingOptions = []
        for v in [videoView, overlay] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        scheduleHide()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { reveal() }
    override func mouseEntered(with event: NSEvent) { reveal() }
    override func mouseExited(with event: NSEvent) { scheduleHide(after: 0.6) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { model.toggleFullscreen() }
        else { window?.makeFirstResponder(self) }
    }

    func reveal() {
        MainActor.assumeIsolated {
            if !model.controlsVisible { withAnimation(.easeOut(duration: 0.18)) { model.controlsVisible = true } }
        }
        NSCursor.unhide()
        scheduleHide()
    }

    func scheduleHide(after s: Double = 2.6) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isPlaying, self.model.hasVideo else { return }
                withAnimation(.easeIn(duration: 0.3)) { self.model.controlsVisible = false }
                if self.window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    func stop() { hideTimer?.invalidate() }

    override func keyDown(with e: NSEvent) {
        MainActor.assumeIsolated {
            reveal()
            switch e.charactersIgnoringModifiers?.lowercased() {
            case ".": model.onStep(1); return
            case ",": model.onStep(-1); return
            case "j": model.onSeek(max(0, model.time - 10)); return
            case "l": model.onSeek(min(model.duration, model.time + 10)); return
            case "m": model.muted.toggle(); model.onMute(model.muted); return
            case "f": model.toggleFullscreen(); return
            default: break
            }
            switch e.keyCode {
            case 126: model.volume = min(1, model.volume + 0.05); model.onVolume(model.volume)
            case 125: model.volume = max(0, model.volume - 0.05); model.onVolume(model.volume)
            default: super.keyDown(with: e)
            }
        }
    }
}

private struct MediaOverlay: View {
    @ObservedObject var model: PlayerModel
    let fileURL: () -> URL?

    var body: some View {
        ZStack(alignment: .bottom) {
            if !model.hasVideo { AudioSheet(model: model) }
            if let s = model.subtitleText, !s.isEmpty {
                Text(s)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .padding(.horizontal, 40)
                    .padding(.bottom, model.controlsVisible ? 92 : 40)
                    .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
                    .allowsHitTesting(false)
            }
            if model.controlsVisible || !model.hasVideo {
                TransportBar(model: model, fileURL: fileURL)
                    .padding(.horizontal, 18).padding(.bottom, 18)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// Audio-only files: a record sleeve on the proofing table.
private struct AudioSheet: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        ZStack {
            Color(nsColor: Theme.stage)
            HStack(spacing: 36) {
                ZStack {
                    if let art = model.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(nsColor: Theme.sheet))
                        Image(systemName: "waveform").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Theme.ember)
                    }
                }
                .frame(width: 220, height: 220).clipped()
                .overlay(CropMarks(gap: 6, length: 12).stroke(Color.primary.opacity(0.3), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "音频")
                    Text(model.title).font(.system(size: 26, weight: .semibold)).lineLimit(2)
                    if !model.artist.isEmpty { Text(model.artist).font(.system(size: 15)).foregroundStyle(.secondary) }
                    if !model.album.isEmpty { Text(model.album).font(.system(size: 13)).foregroundStyle(.tertiary) }
                    Text(model.videoInfo).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 8)
                }
                .frame(maxWidth: 360, alignment: .leading)
            }
            .padding(.bottom, 60)
        }
    }
}

/// Broadcast-monitor style transport: timecode readout, thin scrub rule with playhead.
private struct TransportBar: View {
    @ObservedObject var model: PlayerModel
    let fileURL: () -> URL?
    @State private var scrubbing: Double?
    @State private var hoverX: CGFloat?

    var body: some View {
        VStack(spacing: 8) {
            Scrubber(model: model, scrubbing: $scrubbing, hoverX: $hoverX)
                .frame(height: 18)
            HStack(spacing: 4) {
                Button(action: model.onPlayPause) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 28)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("播放 / 暂停（空格）")
                MediaButton("backward.frame.fill", "后退一帧（,）") { model.onStep(-1) }
                MediaButton("forward.frame.fill", "前进一帧（.）") { model.onStep(1) }
                Text("\(timecode(scrubbing ?? model.time))  /  \(timecode(model.duration))")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { r in
                        Button { model.rate = r; model.onRate(r) } label: {
                            Text(String(format: "%g×", r) + (r == model.rate ? "  ✓" : ""))
                        }
                    }
                } label: {
                    Text(String(format: "%g×", model.rate)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 40).help("播放速度")
                Menu {
                    Button { model.selectedSubtitle = -1; model.onSelectSubtitle(-1) } label: { Text("关闭字幕" + (model.selectedSubtitle == -1 ? "  ✓" : "")) }
                    if !model.subtitleOptions.isEmpty { Divider() }
                    ForEach(Array(model.subtitleOptions.enumerated()), id: \.offset) { i, name in
                        Button { model.selectedSubtitle = i; model.onSelectSubtitle(i) } label: { Text(name + (model.selectedSubtitle == i ? "  ✓" : "")) }
                    }
                    Divider()
                    Button("载入字幕文件…") { model.chooseSubtitleFile(near: fileURL()) }
                } label: {
                    Image(systemName: model.selectedSubtitle >= 0 ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 32).help("字幕")
                if model.hasVideo {
                    MediaButton("camera", "截图（保存到桌面）") { model.onSnapshot() }
                }
                VolumeControl(model: model)
                if model.canPiP { MediaButton("pip.enter", "画中画") { model.onPiP() } }
                if model.hasVideo { MediaButton("arrow.up.left.and.arrow.down.right", "全屏（F）") { model.toggleFullscreen() } }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: 820)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.55)))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
        .environment(\.colorScheme, .dark)
    }

    private func timecode(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "--:--:--" }
        let total = Int(t)
        let frames = Int((t - Double(total)) * 100)
        return String(format: "%02d:%02d:%02d.%02d", total / 3600, (total % 3600) / 60, total % 60, frames)
    }
}

private struct MediaButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    init(_ symbol: String, _ help: String, action: @escaping () -> Void) { self.symbol = symbol; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(hover ? Theme.ember : .white.opacity(0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

private struct VolumeControl: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        HStack(spacing: 4) {
            Button { model.muted.toggle(); model.onMute(model.muted) } label: {
                Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : (model.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                    .font(.system(size: 12)).frame(width: 24, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).help("静音（M）")
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 2)
                    Capsule().fill(.white.opacity(0.9)).frame(width: g.size.width * CGFloat(model.muted ? 0 : model.volume), height: 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let x = max(0, min(1, v.location.x / g.size.width))
                    model.volume = x
                    model.muted = false
                    model.onVolume(x)
                })
            }
            .frame(width: 64, height: 20)
        }
    }
}

/// Thin rule with an ember fill and a vertical playhead; hover shows the time under the pointer.
private struct Scrubber: View {
    @ObservedObject var model: PlayerModel
    @Binding var scrubbing: Double?
    @Binding var hoverX: CGFloat?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let progress = model.duration > 0 ? CGFloat((scrubbing ?? model.time) / model.duration) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18)).frame(height: hoverX != nil || scrubbing != nil ? 4 : 2)
                Rectangle().fill(Theme.ember).frame(width: w * max(0, min(1, progress)), height: hoverX != nil || scrubbing != nil ? 4 : 2)
                // ticks every 10%
                ForEach(1..<10) { i in
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 5).offset(x: w * CGFloat(i) / 10, y: 6)
                }
                Rectangle().fill(.white).frame(width: 2, height: 14)
                    .offset(x: w * max(0, min(1, progress)) - 1)
                if let hx = hoverX, model.duration > 0 {
                    Text(Fmt.duration(Double(hx / w) * model.duration))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.75)))
                        .offset(x: min(max(0, hx - 24), w - 52), y: -18)
                }
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = max(0, min(w, p.x)) } else { hoverX = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let t = Double(max(0, min(w, v.location.x)) / w) * model.duration
                    scrubbing = t
                    model.onSeek(t)
                }
                .onEnded { _ in scrubbing = nil })
        }
    }
}
