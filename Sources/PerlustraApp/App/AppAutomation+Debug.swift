import AppKit
import PerlustraCore

#if DEBUG
    /// Scripted steps, screenshots and memory checks for tests. Not in release builds.
    extension AppAutomation {
        func runCommands(_ wc: ViewerWindowController) async {
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
                    AppDelegate.shared?.openInTab(
                        URL(fileURLWithPath: String(c.dropFirst(4))), from: NSApp.keyWindow?.windowController as? ViewerWindowController ?? wc)
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
                    // Real key presses to the key window (a popover's, when one is open): keys:down,down,return.
                    // Queued, not sent, so the app's key monitors see them as they see a keyboard.
                    guard let w = NSApp.keyWindow ?? wc.window else { break }
                    let codes: [String: (UInt16, String)] = [
                        "up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"),
                        "right": (124, "\u{F703}"), "return": (36, "\r"),
                    ]
                    print("KEYS first responder", w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
                    for k in c.dropFirst(5).split(separator: ",") {
                        guard let (code, chars) = codes[String(k)] else { continue }
                        for t in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(
                                with: t, location: .zero, modifierFlags: code >= 123 ? [.numericPad, .function] : [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                isARepeat: false, keyCode: code)
                            {
                                NSApp.postEvent(e, atStart: false)
                            }
                        }
                        await sleep(0.4)
                    }
                case let c where c.hasPrefix("type:"):
                    // Types text into whatever has keyboard focus.
                    guard let w = NSApp.keyWindow ?? wc.window else { break }
                    print("TYPE into", String(describing: type(of: w)), w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
                    for ch in c.dropFirst(5) {
                        for t in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(
                                with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: w.windowNumber, context: nil, characters: String(ch),
                                charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)
                            {
                                NSApp.sendEvent(e)
                            }
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
                    print(
                        "WHERE", wc.browser.dir?.path ?? "-", "file=\(wc.model.file?.name ?? "-")",
                        "unsaved=\(wc.model.renderer?.hasUnsavedChanges == true)", "sheet=\(wc.window?.attachedSheet != nil)")
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
                        NSEvent.mouseEvent(
                            with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
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
                            if n.contains("Tab") || n.contains("Titlebar") {
                                print(String(repeating: " ", count: d) + n, v.frame, "hidden=\(v.isHidden) alpha=\(v.alphaValue)")
                            }
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
                case let c where c.hasPrefix("look:"):
                    // Switches the look while running: what doesn't follow shows up against a fresh start.
                    NSApp.appearance = NSAppearance(named: c.hasSuffix("dark") ? .darkAqua : .aqua)
                    await sleep(0.8)
                case "inspector": wc.toggleInfoPanel(nil); await sleep(0.5)
                case "sidebar": wc.toggleFileSidebar(nil); await sleep(0.5)
                case let c where c.hasPrefix("home") || c.hasPrefix("template"):
                    await runHomeCommand(c, wc)
                case let c where c.hasPrefix("addtab:"):
                    wc.addTab(URL(fileURLWithPath: String(c.dropFirst("addtab:".count))))
                    await sleep(0.8)
                case let c where c.hasPrefix("tabdrag:"):
                    // tabdrag:<tab index>,<points> drags a tab with real mouse events.
                    let p = c.dropFirst("tabdrag:".count).split(separator: ",").compactMap { Double($0) }
                    if p.count == 2 { await dragTab(wc, index: Int(p[0]), by: p[1]) }
                    printTabs(wc)
                case let c where c.hasPrefix("soak:"):
                    let p = c.dropFirst("soak:".count).split(separator: "|").map(String.init)
                    await PerformanceProbe(window: wc, fixtures: URL(fileURLWithPath: p[1])).soak(p[0])
                case let c where c.hasPrefix("perf:"):
                    await PerformanceProbe(window: wc, fixtures: URL(fileURLWithPath: String(c.dropFirst("perf:".count)))).run()
                case let c where c.hasPrefix("fsrename:"):
                    let p = c.dropFirst("fsrename:".count).split(separator: "|").map(String.init)
                    wc.performRename(URL(fileURLWithPath: p[0]), to: p[1])
                    await sleep(1)
                    printTabs(wc)
                case let c where c.hasPrefix("fstrash:"):
                    wc.performTrash(URL(fileURLWithPath: String(c.dropFirst("fstrash:".count))))
                    await sleep(1)
                    print("NOTICE \(wc.model.notice?.text ?? "-") action=\(wc.model.notice?.action?.title ?? "-")")
                    printTabs(wc)
                case "fsundo":
                    wc.model.notice?.action?.handler()
                    await sleep(1)
                    printTabs(wc)
                case let c where c.hasPrefix("fsdup:"):
                    wc.duplicateFromSidebar(URL(fileURLWithPath: String(c.dropFirst("fsdup:".count))))
                case "fslist":
                    await sleep(0.5)
                    print("LIST \(wc.browser.dir?.lastPathComponent ?? "-") \(wc.browser.items.map(\.name))")
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
                        wc.ai.debugEndpoint = AIEndpoint(
                            proto: AIProtocol(rawValue: p[0]) ?? .openAI, baseURL: u, model: p[2], apiKey: p.count > 3 ? p[3] : nil)
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
                case let c where c.hasPrefix("aistart:"):
                    // Sends a request and moves on while it is still answering.
                    wc.ai.send(String(c.dropFirst("aistart:".count)))
                case let c where c.hasPrefix("wait:"): await sleep(Double(c.dropFirst("wait:".count)) ?? 1)
                case "aiscroll": printAIScroll(wc)
                case let c where c.hasPrefix("aiwheel:"):
                    // aiwheel:<points>, negative scrolls up. A made-up wheel event has no window, so it can't
                    // pass the check for which view the pointer is over: this does the rest as a real one would.
                    if let sv = wc.ai.scrollFollow.scrollView, let dy = Int32(c.dropFirst("aiwheel:".count)),
                        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -dy, wheel2: 0, wheel3: 0),
                        let e = NSEvent(cgEvent: cg)
                    {
                        wc.ai.scrollFollow.wheelMoved(deltaY: e.scrollingDeltaY)
                        sv.scrollWheel(with: e)
                    }
                    await sleep(0.3)
                    printAIScroll(wc)
                case let c where c.hasPrefix("aidrag:"):
                    // aidrag:<points>,<seconds> drags the scroller's knob through the scroller's own
                    // tracking loop, negative up, printing where the view is on each step of the way.
                    let p = c.dropFirst("aidrag:".count).split(separator: ",").compactMap { Double($0) }
                    if p.count == 2 { dragAIScroller(wc, points: p[0], seconds: p[1]) }
                    printAIScroll(wc)
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

        func printAIScroll(_ wc: ViewerWindowController) {
            let f = wc.ai.scrollFollow
            guard let sv = f.scrollView else { print("AISCROLL no scroll view"); return }
            print(
                String(
                    format: "AISCROLL y=%.0f toBottom=%.0f following=%@ items=%d flipped=%@",
                    sv.contentView.bounds.minY, f.distanceToBottom, "\(f.following)", wc.ai.items.count, "\(sv.documentView?.isFlipped ?? false)"))
        }

        /// Runs the scroller's own mouse tracking with mouse events posted over time, so the app keeps
        /// streaming underneath it just as it does under a real drag.
        func dragAIScroller(_ wc: ViewerWindowController, points: Double, seconds: Double) {
            guard let sv = wc.ai.scrollFollow.scrollView, let scroller = sv.verticalScroller, let window = sv.window else { return }
            let knob = scroller.rect(for: .knob)
            let start = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ dy: Double) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: start.x, y: start.y - dy), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let steps = 20
            var step = 0
            let timer = Timer(timeInterval: seconds / Double(steps), repeats: true) { t in
                MainActor.assumeIsolated {
                    step += 1
                    if step <= steps, let e = event(.leftMouseDragged, points * Double(step) / Double(steps)) {
                        window.postEvent(e, atStart: false)
                    }
                    print(String(format: "DRAG step=%d y=%.0f", step, sv.contentView.bounds.minY))
                    if step == steps + 10 {
                        if let e = event(.leftMouseUp, points) { window.postEvent(e, atStart: false) }
                        t.invalidate()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            if let down = event(.leftMouseDown, 0) { scroller.mouseDown(with: down) }
        }

        func dragTab(_ wc: ViewerWindowController, index: Int, by points: Double) async {
            guard let window = wc.window, let strip = wc.debugTabStripView else { return }
            let step = wc.tabs.chipWidth + TabList.gap
            let start = strip.convert(NSPoint(x: step * (Double(index) + 0.4), y: strip.bounds.midY), to: nil)
            let target = strip.hitTest(strip.convert(start, from: nil))
            print(
                "TABDRAG 命中 \(target.map { String(describing: type(of: $0)) } ?? "无") 能拖窗口=\(target?.mouseDownCanMoveWindow ?? false) key=\(window.isKeyWindow)"
            )
            func send(_ type: NSEvent.EventType, _ dx: Double) {
                guard
                    let e = NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return }
                window.sendEvent(e)
            }
            send(.leftMouseDown, 0)
            await sleep(0.05)
            let steps = 24
            for i in 1...steps {
                send(.leftMouseDragged, points * Double(i) / Double(steps))
                await sleep(0.016)
            }
            send(.leftMouseUp, points)
            await sleep(0.4)
        }

        func printTabs(_ wc: ViewerWindowController) {
            let titles = wc.tabs.docs.map { $0.file?.name ?? "首页" }
            print(
                "TABS count=\(titles.count) windows=\(AppDelegate.shared?.windows.count ?? 0) titles=\(titles) current=\(wc.model.file?.name ?? "首页") folder=\(wc.browser.dir?.path ?? "-")"
            )
        }

        func snapshot(_ urls: [URL], _ wc: ViewerWindowController, _ dir: URL) async {
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

        func capture(_ wc: ViewerWindowController, to out: URL) {
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

        func stress(_ dir: URL, _ rounds: Int, _ wc: ViewerWindowController) async {
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

        func renderOffscreen(_ w: NSWindow, to out: URL) {
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

    /// How long the main thread stalls during everyday actions. A frame is 8 to 16 ms, so anything
    /// longer shows as a hitch. Run with scripts/perf.sh, which measures an optimised build.
    @MainActor
    final class PerformanceProbe {
        private let wc: ViewerWindowController
        private let fixtures: URL
        private var last = CACurrentMediaTime()
        private var worst = 0.0
        private var hitches = 0
        private var rows: [(String, Double, Double, Double)] = []
        /// The stall that decides how an action feels is the one in its first moments.
        private var firstMoments = 0.0
        private var actionStart = 0.0

        init(window: ViewerWindowController, fixtures: URL) {
            wc = window
            self.fixtures = fixtures
        }

        private func measure(_ name: String, settle: Double = 0.45, _ action: () async -> Void) async {
            await sleep(0.15)
            last = CACurrentMediaTime()
            worst = 0
            hitches = 0
            firstMoments = 0
            let start = CACurrentMediaTime()
            actionStart = start
            await action()
            let took = CACurrentMediaTime() - start
            await sleep(settle)
            rows.append((name, took * 1000, firstMoments * 1000, worst * 1000))
        }

        private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

        private func openTab(_ path: String) async {
            let doc = wc.addTab(nil)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var finished = false
                doc.onLoadFinished = { _, _ in
                    guard !finished else { return }
                    finished = true
                    done.resume()
                }
                doc.open(fixtures.appendingPathComponent(path))
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    guard !finished else { return }
                    finished = true
                    done.resume()
                }
            }
        }

        /// Repeats an action for a while, for sampling with `sample`.
        func soak(_ kind: String) async {
            for f in ["docs/README.md", "office/report-styled.xlsx", "docs/outline.pdf", "code/hello.py"] { await openTab(f) }
            await sleep(1)
            print("SOAK start \(getpid())")
            fflush(stdout)
            let docs = wc.tabs.docs.filter { $0.file != nil }
            let end = Date().addingTimeInterval(12)
            var i = 0
            while Date() < end {
                switch kind {
                case "switch":
                    wc.select(docs[i % docs.count])
                default:
                    let m = wc.addTab(nil)
                    await sleep(0.05)
                    wc.closeTab(m)
                }
                i += 1
                await sleep(0.06)
            }
            print("SOAK done \(i)")
        }

        func run() async {
            let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    let gap = now - self.last
                    self.last = now
                    if gap > self.worst { self.worst = gap }
                    if now - self.actionStart < 0.28, gap > self.firstMoments { self.firstMoments = gap }
                    if gap > 0.017 { self.hitches += 1 }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }

            let files = [
                "docs/README.md", "office/report-styled.xlsx", "docs/outline.pdf", "images/photo.jpg", "code/hello.py", "media/h264-aac.mp4", "docs/page.html",
            ]
            for f in files { await measure("打开 \(f)", settle: 0.6) { await openTab(f) } }

            let docs = wc.tabs.docs
            for round in 1...2 {
                for doc in docs where doc.file != nil {
                    await measure("切到 \(doc.file?.name ?? "")（第\(round)次）") { wc.select(doc) }
                }
            }
            await measure("新建标签") { wc.addTab(nil) }
            await measure("侧栏 开") { wc.toggleFileSidebar(nil) }
            await measure("侧栏 关") { wc.toggleFileSidebar(nil) }
            await measure("简介 开") { wc.toggleInfoPanel(nil) }
            await measure("简介 关") { wc.toggleInfoPanel(nil) }
            await measure("AI 面板 开") { wc.setAIPanel(open: true) }
            await measure("AI 面板 关") { wc.setAIPanel(open: false) }

            if let md = docs.first(where: { $0.renderer is MarkdownRenderer }), let r = md.renderer as? MarkdownRenderer {
                wc.select(md)
                for (mode, name) in [(0, "阅读"), (2, "源码"), (1, "写作")] {
                    await measure("Markdown 切到\(name)", settle: 0.6) { r.mode = mode }
                }
            }
            if let sheet = docs.first(where: { $0.renderer is SpreadsheetRenderer }), let r = sheet.renderer as? SpreadsheetRenderer {
                wc.select(sheet)
                await measure("切工作表") { r.switchSheet(min(1, max(0, r.workbook.sheets.count - 1))) }
                await measure("切回工作表") { r.switchSheet(0) }
            }
            await measure("切到黑色") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            await measure("切到浅色") { NSApp.appearance = NSAppearance(named: .aqua) }

            for doc in Array(wc.tabs.docs.reversed()) where wc.tabs.docs.count > 1 {
                await measure("关闭 \(doc.file?.name ?? "首页")") { wc.closeTab(doc) }
            }

            print("PERF 操作 | 同步耗时ms | 动作时最长卡顿ms | 全程最长卡顿ms")
            for r in rows.sorted(by: { $0.2 > $1.2 }) {
                print(String(format: "PERF %@ | %.0f | %.0f | %.0f", r.0, r.1, r.2, r.3))
            }
        }
    }
#endif
