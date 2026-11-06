import AppKit
import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import LoupeCore

/// Hosts an AVPlayerLayer (HDR-capable) as a plain NSView.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.wantsExtendedDynamicRangeContent = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

enum SubtitleFinder {
    /// Subtitle files next to the media: "movie.srt", "movie.zh.srt", "movie.chs.ass" …
    static func siblings(of url: URL) -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let dir = url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { u in
            SubtitleParser.extensions.contains(u.pathExtension.lowercased()) && u.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base)
        }.sorted { a, b in
            // Prefer SRT, then ASS/SSA, then VTT; then by name.
            let rank = ["srt": 0, "ass": 1, "ssa": 1, "vtt": 2]
            let ra = rank[a.pathExtension.lowercased()] ?? 3, rb = rank[b.pathExtension.lowercased()] ?? 3
            return ra != rb ? ra < rb : a.lastPathComponent < b.lastPathComponent
        }
    }
}

/// AVFoundation playback (MP4/MOV/M4V/MP3/M4A/AAC/FLAC/WAV/AIFF, HEVC, ProRes, HDR).
/// Defers to mpv when a container or codec is unsupported or audio would be silent.
@MainActor
final class MediaRenderer: NSObject, Renderer, AVPictureInPictureControllerDelegate {
    static let engineName = "AVFoundation"
    static func canHandle(_ file: FileContext) -> Bool { true }

    /// Audio codecs AVFoundation is known not to decode (would play silent) → hand over to mpv.
    /// Everything else, including new ones such as APAC spatial audio, stays with AVFoundation.
    static let undecodableAudio: Set<String> = ["dtsc", "dtsh", "dtsl", "dtse", "dtsx", "dtsy", "vorb", "XiVs", "Opus_ogg", "wma2", "wmap", "mlpa", "truehd"]

    let model = PlayerModel()
    private var player: AVPlayer?
    private let videoView = PlayerLayerView()
    private var stage: MediaStageView?
    private var timeObserver: Any?
    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var pip: AVPictureInPictureController?
    private var asset: AVURLAsset?
    private var cues: [SubtitleCue] = []
    private var externalSubs: [URL] = []
    private var legibleOptions: [AVMediaSelectionOption] = []
    private var legibleGroup: AVMediaSelectionGroup?
    private weak var host: RenderHost?
    private var file: FileContext?
    private var naturalSize: CGSize = .zero
    private var codecs: [String] = []
    private var fps: Float = 0
    private var dataRate: Float = 0
    private var dynamicRange: VideoDynamicRange?

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        self.host = host
        let asset = AVURLAsset(url: file.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset
        let (playable, tracks, duration) = try await withThrowingTaskGroup(of: (Bool, [AVAssetTrack], CMTime).self) { group in
            group.addTask { try await asset.load(.isPlayable, .tracks, .duration) }
            group.addTask {
                try await Task.sleep(nanoseconds: 12_000_000_000)
                throw RenderError.unreadable("AVFoundation 解析超时")
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
        try Task.checkCancellation()
        guard playable else { throw RenderError.unsupported("AVFoundation 不支持此容器或编码") }
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw RenderError.unsupported("没有可播放的音视频轨道") }

        // Codec inventory; an audio codec AVFoundation can't decode means silent playback → prefer mpv.
        for t in tracks {
            let descs = (try? await t.load(.formatDescriptions)) ?? []
            for d in descs {
                let code = Self.fourCC(CMFormatDescriptionGetMediaSubType(d))
                codecs.append("\(t.mediaType == .video ? "视频" : t.mediaType == .audio ? "音频" : "轨道") \(Self.codecName(code))")
                if t.mediaType == .video, dynamicRange == nil { dynamicRange = VideoDynamicRange(d) }
                if t.mediaType == .audio, Self.undecodableAudio.contains(code), MPVLibrary.isAvailable {
                    throw RenderError.unsupported("音频编码 \(code.trimmingCharacters(in: .whitespaces)) 无法由 AVFoundation 解码")
                }
            }
        }
        if let v = videoTracks.first {
            let size = (try? await v.load(.naturalSize)) ?? .zero
            let tf = (try? await v.load(.preferredTransform)) ?? .identity
            naturalSize = size.applying(tf).applying(CGAffineTransform(scaleX: 1, y: 1))
            naturalSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
            fps = (try? await v.load(.nominalFrameRate)) ?? 0
            dataRate = (try? await v.load(.estimatedDataRate)) ?? 0
        }

        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.preventsDisplaySleepDuringVideoPlayback = true
        player = p
        videoView.playerLayer.player = p
        model.hasVideo = !videoTracks.isEmpty
        model.duration = duration.seconds.isFinite ? duration.seconds : 0
        model.engineLabel = Self.engineName
        model.window = host.window
        model.title = file.url.deletingPathExtension().lastPathComponent
        model.videoInfo = (codecs + [dynamicRange?.name].compactMap { $0 }).joined(separator: " · ")
        await loadMetadata(asset)
        await loadSubtitles(asset, item: item)
        wire(p, item: item)

        let stage = MediaStageView(model: model, videoView: videoView)
        stage.fileURL = file.url
        self.stage = stage

        // Wait for readiness (or failure) so a broken file falls back immediately.
        try await waitUntilReady(item)
        if model.hasVideo, AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            pip?.delegate = self
            model.canPiP = pip != nil
        }
        p.play()
        return stage
    }

    private func waitUntilReady(_ item: AVPlayerItem) async throws {
        for _ in 0..<100 {
            switch item.status {
            case .readyToPlay: return
            case .failed: throw RenderError.unsupported(item.error?.localizedDescription ?? "无法解码")
            default: try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func wire(_ p: AVPlayer, item: AVPlayerItem) {
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.time = t.seconds
                if self.model.selectedSubtitle >= 0, self.model.selectedSubtitle < self.externalSubs.count {
                    self.model.subtitleText = SubtitleParser.cue(at: t.seconds, in: self.cues)?.text
                }
            }
        }
        rateObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in self?.model.isPlaying = p.timeControlStatus != .paused }
        }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item.status == .failed else { return }
                self.host?.requestFallback(from: self, reason: item.error?.localizedDescription ?? "播放失败")
            }
        }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.isPlaying = false; self?.stage?.reveal()
            }
        }

        model.onPlayPause = { [weak self] in
            guard let self, let p = self.player else { return }
            if p.timeControlStatus == .paused {
                if let d = p.currentItem?.duration.seconds, d.isFinite, p.currentTime().seconds >= d - 0.05 { p.seek(to: .zero) }
                p.rate = Float(self.model.rate)
            } else {
                p.pause()
            }
            self.stage?.reveal()
        }
        model.onSeek = { [weak self] t in
            self?.player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            self?.model.time = t
        }
        model.onStep = { [weak self] n in
            self?.player?.pause()
            self?.player?.currentItem?.step(byCount: n)
        }
        model.onVolume = { [weak self] v in
            self?.player?.volume = Float(v); self?.player?.isMuted = false
        }
        model.onMute = { [weak self] m in self?.player?.isMuted = m }
        model.onRate = { [weak self] r in
            guard let p = self?.player else { return }
            p.defaultRate = Float(r)
            if p.timeControlStatus != .paused { p.rate = Float(r) }
        }
        model.onSnapshot = { [weak self] in self?.snapshot() }
        model.onPiP = { [weak self] in
            guard let pip = self?.pip else { return }
            pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
        }
        model.onSelectSubtitle = { [weak self] i in self?.selectSubtitle(i) }
        model.onLoadSubtitle = { [weak self] u in self?.addExternalSubtitle(u, select: true) }
    }

    private func loadMetadata(_ asset: AVURLAsset) async {
        let items = (try? await asset.load(.commonMetadata)) ?? []
        for it in items {
            guard let key = it.commonKey else { continue }
            switch key {
            case .commonKeyTitle: if let s = try? await it.load(.stringValue), !s.isEmpty { model.title = s }
            case .commonKeyArtist: model.artist = (try? await it.load(.stringValue)) ?? ""
            case .commonKeyAlbumName: model.album = (try? await it.load(.stringValue)) ?? ""
            case .commonKeyArtwork: if let d = try? await it.load(.dataValue) { model.artwork = NSImage(data: d) }
            default: break
            }
        }
    }

    private func loadSubtitles(_ asset: AVURLAsset, item: AVPlayerItem) async {
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            legibleGroup = group
            legibleOptions = group.options
            item.select(nil, in: group)
        }
        for u in SubtitleFinder.siblings(of: asset.url) { addExternalSubtitle(u, select: false) }
        rebuildSubtitleNames()
        if !externalSubs.isEmpty { selectSubtitle(0) }
    }

    private func addExternalSubtitle(_ u: URL, select: Bool) {
        guard !externalSubs.contains(u) else { return }
        externalSubs.append(u)
        rebuildSubtitleNames()
        if select { selectSubtitle(externalSubs.count - 1) }
    }

    private func rebuildSubtitleNames() {
        model.subtitleOptions = externalSubs.map { "外挂：" + $0.lastPathComponent } + legibleOptions.map { "内嵌：" + $0.displayName }
    }

    private func selectSubtitle(_ i: Int) {
        model.selectedSubtitle = i
        model.subtitleText = nil
        cues = []
        if let g = legibleGroup { player?.currentItem?.select(nil, in: g) }
        guard i >= 0 else { return }
        if i < externalSubs.count {
            let u = externalSubs[i]
            Task {
                let c = await Task.detached { SubtitleParser.parse(url: u) }.value
                self.cues = c
                if c.isEmpty { self.host?.showNotice("字幕文件为空或格式无法识别：\(u.lastPathComponent)", style: .warning, action: nil) }
            }
        } else if let g = legibleGroup, i - externalSubs.count < legibleOptions.count {
            player?.currentItem?.select(legibleOptions[i - externalSubs.count], in: g)
        }
    }

    private func snapshot() {
        guard let asset, let file else { return }
        let t = player?.currentTime() ?? .zero
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let name = file.url.deletingPathExtension().lastPathComponent
        Task {
            do {
                let (img, actual) = try await gen.image(at: t)
                let url = try MediaSnapshot.save(img, name: name, time: actual.seconds)
                host?.showNotice(
                    "截图已保存到桌面：\(url.lastPathComponent)", style: .success,
                    action: NoticeAction(title: "显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            } catch {
                host?.showNotice("截图失败：\(error.localizedDescription)", style: .warning, action: nil)
            }
        }
    }

    static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }

    static func codecName(_ c: String) -> String {
        switch c {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "Dolby Vision"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "ProRes"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4v": return "MPEG-4"
        case "jpeg": return "Motion JPEG"
        case "aac ", "mp4a": return "AAC"
        case ".mp3": return "MP3"
        case "alac": return "ALAC"
        case "flac", "fLaC": return "FLAC"
        case "lpcm", "sowt", "twos": return "PCM"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "opus": return "Opus"
        case "apac": return "APAC 空间音频"
        default: return c.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    func willBeReplaced() { player?.pause() }

    func cleanup() {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        statusObs = nil
        rateObs = nil
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        pip = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        videoView.playerLayer.player = nil
        player = nil
        stage?.stop()
        asset = nil
    }

    var presentation: StagePresentation { .bleed }
    var controlsPlacement: ControlsPlacement { .none }
    var wantsSpaceKey: Bool { true }
    var initialFirstResponder: NSView? { stage }

    func supports(_ c: ViewerCommand) -> Bool { c == .playPause }
    func perform(_ c: ViewerCommand) { if c == .playPause { model.onPlayPause() } }

    var statusText: String {
        var parts: [String] = []
        if model.duration > 0 { parts.append(Fmt.duration(model.duration)) }
        if naturalSize.width > 0 { parts.append("\(Int(naturalSize.width)) × \(Int(naturalSize.height))") }
        if fps > 0 { parts.append(String(format: "%.3g fps", fps)) }
        if !codecs.isEmpty { parts.append(codecs.map { $0.components(separatedBy: " ").last ?? $0 }.joined(separator: "/")) }
        return parts.joined(separator: " · ")
    }

    var infoSections: [InfoSection] {
        var items = [InfoItem("时长", Fmt.duration(model.duration))]
        if naturalSize.width > 0 { items.append(InfoItem("分辨率", "\(Int(naturalSize.width)) × \(Int(naturalSize.height))")) }
        if fps > 0 { items.append(InfoItem("帧率", String(format: "%.3f fps", fps))) }
        for c in codecs { items.append(InfoItem("编码", c)) }
        if dataRate > 0 { items.append(InfoItem("视频码率", String(format: "%.1f Mbps", dataRate / 1_000_000))) }
        if let dynamicRange {
            items.append(InfoItem("动态范围", dynamicRange.detail))
            if dynamicRange.isHDR, let screen = host?.window?.screen {
                let shows = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
                items.append(InfoItem("当前屏幕", shows ? "能显示 HDR" : "不能显示 HDR，亮部会被压缩，看起来发灰"))
            }
        }
        if !model.artist.isEmpty { items.append(InfoItem("艺术家", model.artist)) }
        if !model.album.isEmpty { items.append(InfoItem("专辑", model.album)) }
        if !externalSubs.isEmpty || !legibleOptions.isEmpty { items.append(InfoItem("字幕", "\(externalSubs.count) 个外挂 · \(legibleOptions.count) 个内嵌")) }
        items.append(InfoItem("引擎", "AVFoundation（原画质 · 支持 HDR）"))
        return [InfoSection("影音", items)]
    }
}

/// What a video's brightness range is, which decides how much of it this screen can show.
struct VideoDynamicRange {
    enum Kind { case sdr, hlg, pq, dolbyVision }
    var kind: Kind
    var bitDepth: Int?

    init(kind: Kind, bitDepth: Int? = nil) {
        self.kind = kind
        self.bitDepth = bitDepth
    }

    init(_ format: CMFormatDescription) {
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        let code = CMFormatDescriptionGetMediaSubType(format)
        let dolby = atoms?["dvcC"] != nil || atoms?["dvvC"] != nil || code == 0x6476_6831 || code == 0x6476_6865  // dvh1, dvhe
        if dolby {
            kind = .dolbyVision
        } else if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
            kind = .hlg
        } else if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
            kind = .pq
        } else {
            kind = .sdr
        }
        bitDepth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
    }

    var isHDR: Bool { kind != .sdr }

    var name: String {
        switch kind {
        case .sdr: return "SDR"
        case .hlg: return "HDR（HLG）"
        case .pq: return "HDR10"
        case .dolbyVision: return "杜比视界"
        }
    }

    var detail: String { name + (bitDepth.map { " · \($0) bit" } ?? "") }
}

enum MediaSnapshot {
    static func save(_ img: CGImage, name: String, time: Double) throws -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let stamp = Fmt.duration(time).replacingOccurrences(of: ":", with: ".")
        let url = desktop.appendingPathComponent("\(name) 截图 \(stamp).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.unreadable("无法写入截图")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.unreadable("无法写入截图") }
        return url
    }
}
