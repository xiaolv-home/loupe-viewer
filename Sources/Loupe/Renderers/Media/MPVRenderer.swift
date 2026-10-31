import AppKit
import SwiftUI
import OpenGL.GL3
import LoupeCore

/// Plays everything AVFoundation can't (MKV, AVI, WMV, FLV, RMVB, TS, WebM, Opus, APE…)
/// through libmpv embedded in the window with VideoToolbox hardware decoding.
@MainActor
final class MPVRenderer: NSObject, Renderer {
    static let engineName = "mpv"
    static func canHandle(_ file: FileContext) -> Bool { true }

    let model = PlayerModel()
    private var player: MPVPlayer?
    private var videoView: MPVVideoView?
    private var stage: MediaStageView?
    private weak var host: RenderHost?
    private var file: FileContext?
    private var externalProcess: Process?
    private var fallbackView: NSView?
    private var mode = "embedded"
    private var subtitleIDs: [Int] = []
    private var videoParams = ""

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        self.host = host
        guard let lib = MPVLibrary.load() else {
            // 影音链后面没有十六进制兜底。库缺失时这页就是终点（安装提示），
            // 所以这里返回视图而不是抛错。渲染中途失败走 onRenderFailure，改开独立窗口。
            mode = "missing"
            let v = NSHostingView(rootView: MPVMissingView(file: file))
            v.sizingOptions = []
            return v
        }
        guard let p = MPVPlayer(api: lib.api) else { return try externalFallback(file, reason: "libmpv 初始化失败") }
        player = p
        let vv = MPVVideoView()
        vv.glLayer.player = p
        p.layer = vv.glLayer
        videoView = vv
        model.engineLabel = "mpv"
        model.window = host.window
        model.title = file.url.deletingPathExtension().lastPathComponent
        model.canPiP = false
        wire(p)
        p.createRenderContext()
        guard p.renderContext != nil else {
            p.destroy()
            player = nil
            return try externalFallback(file, reason: "OpenGL 渲染上下文创建失败")
        }

        let stage = MediaStageView(model: model, videoView: vv)
        stage.fileURL = file.url
        self.stage = stage

        let loaded: Bool = await withCheckedContinuation { cont in
            var done = false
            p.onLoaded = { if !done { done = true; cont.resume(returning: true) } }
            p.onEndFile = { failed in if failed && !done { done = true; cont.resume(returning: false) } }
            p.command(["loadfile", file.url.path])
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { if !done { done = true; cont.resume(returning: false) } }
        }
        guard loaded else {
            p.destroy()
            player = nil
            throw RenderError.unsupported("mpv 无法解码此文件")
        }
        afterLoad(p)
        return stage
    }

    private func wire(_ p: MPVPlayer) {
        p.onEvent = { [weak self] name, value in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch name {
                case "time-pos": if let v = value as? Double { self.model.time = v }
                case "duration": if let v = value as? Double { self.model.duration = v; self.host?.rendererDidUpdate() }
                case "pause": if let v = value as? Bool { self.model.isPlaying = !v }
                case "volume": if let v = value as? Double { self.model.volume = v / 100 }
                case "eof-reached": if value as? Bool == true { self.model.isPlaying = false; self.stage?.reveal() }
                case "video-reconfig": if let p = self.player { self.updateStreamInfo(p) }
                default: break
                }
            }
        }
        p.onRenderFailure = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let file = self.file, self.mode == "embedded" else { return }
                self.videoView?.glLayer.player = nil
                self.player?.destroy()
                self.player = nil
                do {
                    let v = try self.externalFallback(file, reason: "嵌入渲染初始化失败")
                    if let parent = self.stage?.superview {
                        v.frame = parent.bounds
                        v.autoresizingMask = [.width, .height]
                        self.stage?.removeFromSuperview()
                        parent.addSubview(v)
                        self.fallbackView = v
                    }
                    self.host?.showNotice("mpv 嵌入渲染不可用，已改用独立窗口播放。", style: .warning, action: nil)
                    self.host?.rendererDidUpdate()
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.host?.showNotice("mpv 嵌入渲染失败：\(msg)", style: .warning, action: nil)
                }
            }
        }
        model.onPlayPause = { [weak self] in self?.player?.command(["cycle", "pause"]); self?.stage?.reveal() }
        model.onSeek = { [weak self] t in self?.player?.command(["seek", String(format: "%.3f", t), "absolute+exact"]); self?.model.time = t }
        model.onStep = { [weak self] n in self?.player?.command([n > 0 ? "frame-step" : "frame-back-step"]) }
        model.onVolume = { [weak self] v in self?.player?.set("volume", double: v * 100); self?.player?.set("mute", flag: false) }
        model.onMute = { [weak self] m in self?.player?.set("mute", flag: m) }
        model.onRate = { [weak self] r in self?.player?.set("speed", double: r) }
        model.onSnapshot = { [weak self] in self?.snapshot() }
        model.onSelectSubtitle = { [weak self] i in
            guard let self, let p = self.player else { return }
            if i < 0 || i >= self.subtitleIDs.count { p.command(["set", "sid", "no"]) }
            else { p.command(["set", "sid", "\(self.subtitleIDs[i])"]) }
        }
        model.onLoadSubtitle = { [weak self] u in
            self?.player?.command(["sub-add", u.path, "select"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshTracks() }
        }
    }

    private func afterLoad(_ p: MPVPlayer) {
        let n = Int(p.string("track-list/count") ?? "0") ?? 0
        let types = (0..<n).compactMap { p.string("track-list/\($0)/type") }
        // Cover art in audio files shows up as an "albumart" video track; treat those as audio.
        let realVideo = (0..<n).contains { p.string("track-list/\($0)/type") == "video" && p.string("track-list/\($0)/albumart") != "yes" }
        model.hasVideo = realVideo
        if !types.contains("video") && !types.contains("audio") { model.hasVideo = false }
        if let t = p.string("metadata/by-key/title"), !t.isEmpty { model.title = t }
        model.artist = p.string("metadata/by-key/artist") ?? ""
        model.album = p.string("metadata/by-key/album") ?? ""
        updateStreamInfo(p)
        refreshTracks()
    }

    private func updateStreamInfo(_ p: MPVPlayer) {
        let vcodec = p.string("video-format") ?? p.string("video-codec") ?? ""
        let acodec = p.string("audio-codec-name") ?? ""
        let w = p.string("video-params/w") ?? p.string("width") ?? ""
        let h = p.string("video-params/h") ?? p.string("height") ?? ""
        let fps = Double(p.string("container-fps") ?? "") ?? 0
        videoParams = [model.hasVideo && !w.isEmpty ? "\(w) × \(h)" : nil,
                       fps > 0 && model.hasVideo ? String(format: "%.3g fps", fps) : nil,
                       vcodec.isEmpty || !model.hasVideo ? nil : vcodec.uppercased(),
                       acodec.isEmpty ? nil : acodec.uppercased()].compactMap { $0 }.joined(separator: " · ")
        model.videoInfo = videoParams
        host?.rendererDidUpdate()
    }

    private func refreshTracks() {
        guard let p = player else { return }
        let n = Int(p.string("track-list/count") ?? "0") ?? 0
        var names: [String] = []
        var ids: [Int] = []
        var selected = -1
        for i in 0..<n where p.string("track-list/\(i)/type") == "sub" {
            let id = Int(p.string("track-list/\(i)/id") ?? "") ?? 0
            let title = p.string("track-list/\(i)/title") ?? p.string("track-list/\(i)/external-filename").map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let lang = p.string("track-list/\(i)/lang") ?? ""
            let ext = p.string("track-list/\(i)/external") == "yes"
            names.append((ext ? "外挂：" : "内嵌：") + ([title, lang].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty("轨道 \(id)")))
            if p.string("track-list/\(i)/selected") == "yes" { selected = ids.count }
            ids.append(id)
        }
        subtitleIDs = ids
        model.subtitleOptions = names
        model.selectedSubtitle = selected
    }

    private func snapshot() {
        guard let p = player, let file else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent("\(file.url.deletingPathExtension().lastPathComponent) 截图 \(Fmt.duration(model.time).replacingOccurrences(of: ":", with: ".")).png")
        p.command(["screenshot-to-file", url.path, "video"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if FileManager.default.fileExists(atPath: url.path) {
                self?.host?.showNotice("截图已保存到桌面：\(url.lastPathComponent)", style: .success,
                                       action: NoticeAction(title: "显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
        }
    }

    /// Last resort: hand the file to the mpv executable in its own window.
    private func externalFallback(_ file: FileContext, reason: String) throws -> NSView {
        guard let exe = MPVLibrary.executable else { throw RenderError.unsupported(reason) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["--force-window=yes", "--ytdl=no", "--keep-open=yes", file.url.path]
        try proc.run()
        externalProcess = proc
        mode = "external"
        let v = NSHostingView(rootView: MPVExternalView(file: file, reason: reason))
        v.sizingOptions = []
        return v
    }

    func willBeReplaced() { player?.command(["set", "pause", "yes"]) }

    func cleanup() {
        stage?.stop()
        player?.onEvent = nil
        player?.onEndFile = nil
        player?.onLoaded = nil
        player?.command(["stop"])
        player?.destroy()
        player = nil
        videoView?.glLayer.player = nil
        videoView = nil
        fallbackView?.removeFromSuperview()
        fallbackView = nil
        if let p = externalProcess, p.isRunning { p.terminate() }
        externalProcess = nil
    }

    var presentation: StagePresentation { mode == "embedded" ? .bleed : .sheet }
    var controlsPlacement: ControlsPlacement { .none }
    var wantsSpaceKey: Bool { mode == "embedded" }
    var initialFirstResponder: NSView? { stage }
    func supports(_ c: ViewerCommand) -> Bool { c == .playPause && mode == "embedded" }
    func perform(_ c: ViewerCommand) { if c == .playPause { model.onPlayPause() } }

    var statusText: String {
        switch mode {
        case "missing": return "需要 mpv"
        case "external": return "mpv 独立窗口"
        default: return ([model.duration > 0 ? Fmt.duration(model.duration) : nil, videoParams.isEmpty ? nil : videoParams] as [String?]).compactMap { $0 }.joined(separator: " · ")
        }
    }

    var infoSections: [InfoSection] {
        var items = [InfoItem("引擎", mode == "embedded" ? "libmpv（内嵌 · VideoToolbox 硬件解码）" : (mode == "external" ? "mpv 独立窗口" : "未安装"))]
        if let lib = MPVLibrary.load() { items.append(InfoItem("libmpv", lib.path)) }
        if model.duration > 0 { items.append(InfoItem("时长", Fmt.duration(model.duration))) }
        if !videoParams.isEmpty { items.append(InfoItem("流", videoParams)) }
        if let hw = player?.string("hwdec-current"), !hw.isEmpty { items.append(InfoItem("硬件解码", hw == "no" ? "未启用" : hw)) }
        if let scale = player?.string("scale"), !scale.isEmpty {
            items.append(InfoItem("画质", "高画质预设 · 放大 \(scale) · 输出 Display P3（系统色彩管理）"))
        }
        return [InfoSection("影音", items)]
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

private struct MPVMissingView: View {
    let file: FileContext
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "需要 MPV")
            Text("此格式需要 mpv 才能播放").font(.system(size: 20, weight: .semibold))
            Text("系统自带的 AVFoundation 无法解码「\(file.name)」。安装开源播放器 mpv 后，Loupe 会自动检测并在窗口内直接播放（支持 MKV、AVI、WMV、FLV、RMVB、WebM 等）。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("brew install mpv").font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    .textSelection(.enabled)
                Button("拷贝命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install mpv", forType: .string)
                }
            }
            HStack(spacing: 10) {
                Button("用默认应用打开") { NSWorkspace.shared.open(file.url) }
                Button("在设置中指定 libmpv…") { AppDelegate.shared?.showSettings(nil) }
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MPVExternalView: View {
    let file: FileContext
    let reason: String
    var body: some View {
        VStack(spacing: 12) {
            SectionLabel(text: "MPV · 独立窗口")
            Text("正在用 mpv 独立窗口播放").font(.system(size: 18, weight: .semibold))
            Text("\(reason)，已改用 mpv 自身的窗口。关闭本文件会同时结束播放。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
