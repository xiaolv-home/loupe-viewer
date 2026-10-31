import AppKit
import LoupeCore

/// Command-line automation used by the test scripts:
///   --probe                 print which engine rendered each file (JSON lines) and quit
///   --snapshot DIR          save a PNG of the window per file into DIR
///   --stress DIR --rounds N open every file in DIR N times and report memory
///   --delay S  --size WxH  --appearance dark|light  --inspector  --sidebar  --cmd NAME
@MainActor
final class DebugHarness {
    enum Mode { case none, probe, snapshot(URL), stress(URL, Int) }
    private(set) var mode: Mode = .none
    var delay: Double = 1.2
    var hold: Double = 0
    var size: NSSize?
    var appearance: NSAppearance.Name?
    var showInspector = false
    var showSidebar = false
    var commands: [String] = []
    private var captureOverride: NSWindow?
    var isActive: Bool { if case .none = mode { return false }; return true }

    func parse(_ args: [String]) -> [URL] {
        var urls: [URL] = []
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--probe": mode = .probe
            case "--snapshot": if let d = next() { mode = .snapshot(URL(fileURLWithPath: d)) }
            case "--stress":
                if let d = next() { mode = .stress(URL(fileURLWithPath: d), 2) }
            case "--rounds":
                if let n = next().flatMap(Int.init), case .stress(let d, _) = mode { mode = .stress(d, n) }
            case "--delay": delay = next().flatMap(Double.init) ?? delay
            case "--hold": hold = next().flatMap(Double.init) ?? 0
            case "--size":
                if let s = next() {
                    let p = s.split(separator: "x").compactMap { Double($0) }
                    if p.count == 2 { size = NSSize(width: p[0], height: p[1]) }
                }
            case "--appearance": appearance = next() == "dark" ? .darkAqua : .aqua
            case "--inspector": showInspector = true
            case "--sidebar": showSidebar = true
            case "--cmd": if let c = next() { commands.append(c) }
            default:
                if a.hasPrefix("-") {
                    // Skip system arguments such as -NSDocumentRevisionsDebugMode YES / -psn_…
                    if !a.hasPrefix("-psn"), i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
                } else {
                    urls.append(URL(fileURLWithPath: a).standardizedFileURL)
                }
            }
            i += 1
        }
        return urls
    }

    func run(urls: [URL], app: AppDelegate) {
        if let appearance { NSApp.appearance = NSAppearance(named: appearance) }
        guard let wc = app.newWindow(), let window = wc.window else { exit(2) }
        if let size { window.setContentSize(size); window.center() }
        wc.showWindow(nil)
        if showInspector { wc.toggleInfoPanel(nil) }
        if showSidebar { wc.toggleFileSidebar(nil) }
        Task { @MainActor in
            switch mode {
            case .probe: await probe(urls, wc)
            case .snapshot(let dir): await snapshot(urls, wc, dir)
            case .stress(let dir, let rounds): await stress(dir, rounds, wc)
            case .none: break
            }
            if hold > 0 { print("holding pid \(getpid())"); fflush(stdout); await sleep(hold) }
            exit(0)
        }
    }

    private func load(_ url: URL, _ wc: ViewerWindowController, timeout: Double = 20) async -> (String, [String]) {
        await withCheckedContinuation { (cont: CheckedContinuation<(String, [String]), Never>) in
            var done = false
            wc.model.onLoadFinished = { engine, failures in
                guard !done else { return }
                done = true
                cont.resume(returning: (engine, failures))
            }
            wc.open(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                cont.resume(returning: ("timeout", []))
            }
        }
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func runCommands(_ wc: ViewerWindowController) async {
        for c in commands {
            switch c {
            case "toggleSource": wc.model.perform(.toggleSource)
            case "actualSize": wc.model.perform(.actualSize)
            case "zoomIn": wc.model.perform(.zoomIn)
            case "rotate": wc.model.perform(.rotateRight)
            case "find": wc.model.perform(.find)
            case "play": wc.model.perform(.playPause)
            case "slideshow": wc.model.perform(.slideshow); await sleep(25)
            case "empty": wc.model.close(); wc.stage.showEmpty()
            case let c where c.hasPrefix("offscreen:"):
                if let w = wc.window { renderOffscreen(w, to: URL(fileURLWithPath: String(c.dropFirst(10)))) }
            case let c where c.hasPrefix("tab:"):
                AppDelegate.shared?.openInTab(URL(fileURLWithPath: String(c.dropFirst(4))), from: NSApp.keyWindow?.windowController as? ViewerWindowController ?? wc)
                await sleep(1.2)
                printTabs(wc)
            case let c where c.hasPrefix("browse:"):
                wc.browser.show(URL(fileURLWithPath: String(c.dropFirst(7))))
                await sleep(0.5)
                print("BROWSE", wc.browser.dir?.path ?? "-", wc.browser.items.prefix(6).map { ($0.isFolder ? "📁" : "") + $0.name })
            case "up":
                wc.browser.goUp()
                await sleep(0.5)
                print("BROWSE", wc.browser.dir?.path ?? "-", wc.browser.items.prefix(6).map { ($0.isFolder ? "📁" : "") + $0.name })
            case let c where c.hasPrefix("keys:"):
                // Real key presses to the key window (a popover's, when one is open): keys:down,down,return
                guard let w = NSApp.keyWindow ?? wc.window else { break }
                let codes: [String: (UInt16, String)] = ["up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"),
                                                          "right": (124, "\u{F703}"), "return": (36, "\r")]
                print("KEYS first responder", w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
                for k in c.dropFirst(5).split(separator: ",") {
                    guard let (code, chars) = codes[String(k)] else { continue }
                    for t in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: code >= 123 ? [.numericPad, .function] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                    isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
                    }
                    await sleep(0.4)
                }
            case let c where c.hasPrefix("type:"):
                // Types text into whatever has keyboard focus.
                guard let w = NSApp.keyWindow ?? wc.window else { break }
                print("TYPE into", String(describing: type(of: w)), w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
                for ch in c.dropFirst(5) {
                    for t in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, characters: String(ch),
                                                    charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) { NSApp.sendEvent(e) }
                    }
                }
                await sleep(0.3)
            case "focuslist":
                // Gives the sidebar list keyboard focus, as clicking into it does.
                func find(_ v: NSView) -> NSView? {
                    if String(describing: type(of: v)).contains("OutlineListView") { return v }
                    for sub in v.subviews { if let f = find(sub) { return f } }
                    return nil
                }
                if let w = wc.window, let root = w.contentView?.superview, let list = find(root) { w.makeFirstResponder(list) }
            case "where":
                await sleep(0.8)
                print("WHERE", wc.browser.dir?.path ?? "-")
            case "activate":
                NSApp.activate(ignoringOtherApps: true)
                wc.window?.makeKeyAndOrderFront(nil)
                await sleep(1)
            case "closetab": wc.closeTabAction(nil); await sleep(0.4); printTabs(wc)
            case "nexttab": wc.nextTab(nil); await sleep(0.3); printTabs(wc)
            case let c where c.hasPrefix("clickat:"):
                // A real mouse click at (x, y) points from the window's top-left.
                guard let w = wc.window else { break }
                let n = c.dropFirst(8).split(separator: ",").compactMap { Double($0) }
                guard n.count == 2 else { break }
                let p = NSPoint(x: n[0], y: w.frame.height - n[1])
                let hit = w.contentView?.superview?.hitTest(w.contentView!.superview!.convert(p, from: nil))
                print("CLICK key=\(w.isKeyWindow) active=\(NSApp.isActive) at", p, "hit", hit.map { String(describing: type(of: $0)) } ?? "nil")
                // The mouse-up waits in the queue, as a real one would: controls that track the
                // mouse (tables, buttons) take it from there while handling the mouse-down.
                func ev(_ t: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let up = ev(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
                if let down = ev(.leftMouseDown) { NSApp.sendEvent(down) }
                await sleep(0.6)
                print("BROWSE", wc.browser.dir?.path ?? "-", "| tabs", wc.tabs.docs.map { $0.file?.name ?? "首页" })
            case "tabs":
                printTabs(wc)
                // Where AppKit put the tab bar (diagnostics).
                if let frame = wc.window?.contentView?.superview {
                    func walk(_ v: NSView, _ d: Int) {
                        let n = String(describing: type(of: v))
                        if n.contains("Tab") || n.contains("Titlebar") { print(String(repeating: " ", count: d) + n, v.frame, "hidden=\(v.isHidden) alpha=\(v.alphaValue)") }
                        if d < 9 { v.subviews.forEach { walk($0, d + 1) } }
                    }
                    walk(frame, 0)
                }
                print("TABBAR visible=\(wc.window?.tabGroup?.isTabBarVisible ?? false)")
            case "dump": if let r = wc.model.renderer as? DebugScriptable { print("DUMP", r.debugDump()) }
            case "hittest":
                // Which view receives a click at each point of the window (diagnoses invisible overlays).
                guard let w = wc.window, let frameView = w.contentView?.superview else { break }
                var counts: [String: Int] = [:]
                var samples: [String: String] = [:]
                let b = frameView.bounds
                for xi in stride(from: 20.0, to: b.width - 20, by: 40) {
                    for yi in stride(from: 20.0, to: b.height - 60, by: 30) {
                        let p = NSPoint(x: xi, y: yi)
                        let v = frameView.hitTest(p)
                        var name = v.map { String(describing: type(of: $0)) } ?? "nil"
                        if let v, v.className.contains("Hosting") || name.contains("Hosting") {
                            var anc = v.superview; var chain = name
                            while let a = anc, chain.count < 160 { chain += " < " + String(describing: type(of: a)); anc = a.superview }
                            name = chain
                        }
                        counts[name, default: 0] += 1
                        samples[name] = samples[name] ?? "(\(Int(xi)),\(Int(yi)))"
                    }
                }
                for (k, n) in counts.sorted(by: { $0.value > $1.value }) { print("HIT", n, k.prefix(200), samples[k] ?? "") }
            case let c where c.hasPrefix("sheet:") || c.hasPrefix("do:"):
                // Renderer-specific script: sheet:<verb>:<args>.
                guard let r = wc.model.renderer as? DebugScriptable, let w = wc.window else { print("SHEET not scriptable"); break }
                let parts = c.split(separator: ":", maxSplits: 2).map(String.init)
                await r.debugRun(verb: parts.count > 1 ? parts[1] : "", arg: parts.count > 2 ? parts[2] : "", window: w)
            case "newmd":
                AppDelegate.shared?.newMarkdownDocument(nil)
                await sleep(3)
                printTabs(wc)
            case "aipanel": wc.setAIPanel(open: true); await sleep(0.6)
            case "skills":
                for sk in AISkills.shared.all { print("SKILL \(sk.builtIn ? "built-in" : "installed") \(sk.name) — \(sk.description.prefix(60))") }
            case let c where c.hasPrefix("installskill:"):
                do {
                    let got = try await AISkills.shared.install(String(c.dropFirst("installskill:".count)))
                    for sk in got { print("INSTALLED \(sk.name) files=\(sk.resourceFiles().count) desc=\(sk.description.prefix(50))") }
                } catch { print("INSTALL FAILED \(error.localizedDescription)") }
            case let c where c.hasPrefix("aiendpoint:"):
                // aiendpoint:anthropic|http://127.0.0.1:9911|claude-opus-5-5|key
                let p = c.dropFirst("aiendpoint:".count).split(separator: "|").map(String.init)
                if p.count >= 3, let u = URL(string: p[1]) {
                    wc.ai.debugEndpoint = AIEndpoint(proto: AIProtocol(rawValue: p[0]) ?? .openAI, baseURL: u, model: p[2], apiKey: p.count > 3 ? p[3] : nil)
                }
            case let c where c.hasPrefix("aiattach:"):
                wc.ai.attach(files: [URL(fileURLWithPath: String(c.dropFirst("aiattach:".count)))])
                print("ATTACHED \(wc.ai.attachments.count)")
            case let c where c.hasPrefix("aikey:"):
                // aikey:provider|value — stores a key the way 设置 does (scratch folder when scripted).
                let p = c.dropFirst("aikey:".count).split(separator: "|", maxSplits: 1).map(String.init)
                if p.count == 2 { AIConfig.shared.setAPIKey(p[1], for: CloudProvider.find(p[0])) }
                print("KEY \(p.first ?? "") = \(AIConfig.shared.apiKey(CloudProvider.find(p.first ?? "")) == nil ? "none" : "set")")
            case "aihistory":
                for (i, h) in AIConversations.shared.list.enumerated() { print("HISTORY \(i) \(h.title) | \(h.file ?? "-") | \(h.preview.prefix(40))") }
            case "aihistorypanel": wc.ai.showHistory = true; await sleep(0.5)
            case "ainew": wc.ai.newChat()
            case let c where c.hasPrefix("aiopen:"):
                if let i = Int(c.dropFirst("aiopen:".count)), AIConversations.shared.list.indices.contains(i) {
                    wc.ai.open(AIConversations.shared.list[i].id)
                    for item in wc.ai.items { print("OPENED " + item.debugLine.prefix(120)) }
                }
            case let c where c.hasPrefix("aidelete:"):
                if let i = Int(c.dropFirst("aidelete:".count)), AIConversations.shared.list.indices.contains(i) {
                    wc.ai.deleteConversation(AIConversations.shared.list[i].id)
                }
            case let c where c.hasPrefix("aiapprove:"):
                wc.ai.debugAutoApprove = c.dropFirst("aiapprove:".count) == "yes"
            case let c where c.hasPrefix("aiskill:"):
                wc.ai.pinnedSkill = AISkills.shared.find(String(c.dropFirst("aiskill:".count)))
            case let c where c.hasPrefix("ai:"):
                // Sends a request to the AI and prints everything it did once it finishes.
                let config = AIConfig.shared
                if wc.ai.debugEndpoint == nil, config.mode == .local, (try? config.endpoint()) == nil, let found = await config.detectLocal() {
                    config.localBaseURL = found.base
                    config.localModel = AIModelList.preferred(found.models)
                }
                print("AI endpoint \(config.summary)")
                let started = Date()
                wc.ai.send(String(c.dropFirst(3)))
                while wc.ai.running && Date().timeIntervalSince(started) < 900 { await sleep(0.5) }
                for item in wc.ai.items { print("AI " + item.debugLine) }
                print(String(format: "AI done in %.0fs", Date().timeIntervalSince(started)))
            case "aisettings": AppDelegate.showAISettings(); await sleep(0.5); captureOverride = NSApp.windows.first { $0.title == "设置" }
            case let c where c.hasPrefix("skillswindow"):
                AISkillsWindow.show(market: c.hasSuffix(":market"))
                await sleep(0.6)
                captureOverride = NSApp.windows.first { $0.title == "技能库" }
            case "settings": AppDelegate.shared?.showSettings(nil); captureOverride = NSApp.windows.first { $0.title == "设置" }
            case "shortcuts": AppDelegate.shared?.showShortcuts(nil); captureOverride = NSApp.windows.first { $0.title == "键盘快捷键" }
            default: break
            }
            await sleep(0.4)
        }
    }

    private func printTabs(_ wc: ViewerWindowController) {
        let titles = wc.tabs.docs.map { $0.file?.name ?? "首页" }
        print("TABS count=\(titles.count) windows=\(AppDelegate.shared?.windows.count ?? 0) titles=\(titles) current=\(wc.model.file?.name ?? "首页") folder=\(wc.browser.dir?.path ?? "-")")
    }

    private func probe(_ urls: [URL], _ wc: ViewerWindowController) async {
        for u in urls {
            let (engine, failures) = await load(u, wc)
            await sleep(0.3)
            let f = wc.model.file
            let obj: [String: Any] = [
                "file": u.lastPathComponent,
                "family": f?.format.family.rawValue ?? "?",
                "token": f?.format.token ?? "?",
                "engine": engine,
                "mismatch": f?.format.extensionMismatch ?? false,
                "status": wc.model.statusText,
                "failures": failures
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: d, encoding: .utf8) {
                print(s)
                fflush(stdout)
            }
        }
    }

    private func snapshot(_ urls: [URL], _ wc: ViewerWindowController, _ dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let targets: [URL?] = urls.isEmpty ? [nil] : urls
        for u in targets {
            if let u { _ = await load(u, wc) }
            await sleep(delay)
            await runCommands(wc)
            await sleep(0.3)
            let name = (u?.lastPathComponent ?? "empty") + ".png"
            capture(wc, to: dir.appendingPathComponent(name))
        }
    }

    private func capture(_ wc: ViewerWindowController, to out: URL) {
        guard let w = captureOverride ?? wc.window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", out.path]
        try? p.run()
        p.waitUntilExit()
        if !FileManager.default.fileExists(atPath: out.path) {
            // Screen locked or display asleep: render the window's views off-screen instead.
            renderOffscreen(w, to: out)
        }
        print("snapshot \(out.path)")
        fflush(stdout)
    }

    private func stress(_ dir: URL, _ rounds: Int, _ wc: ViewerWindowController) async {
        let files = ViewerModel.listSiblings(in: dir, showHidden: false)
        print("stress: \(files.count) files × \(rounds) rounds")
        var baseline: Double = 0
        for r in 1...max(1, rounds) {
            for u in files {
                _ = await load(u, wc, timeout: 15)
                await sleep(0.25)
            }
            wc.model.close()
            await sleep(1.0)
            let mb = Self.footprintMB()
            if r == 1 { baseline = mb }
            print(String(format: "round %d: footprint %.1f MB (Δ vs round 1: %+.1f MB)", r, mb, mb - baseline))
            fflush(stdout)
        }
    }

    private func renderOffscreen(_ w: NSWindow, to out: URL) {
        guard let root = w.contentView?.superview ?? w.contentView else { return }
        root.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        root.display()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
