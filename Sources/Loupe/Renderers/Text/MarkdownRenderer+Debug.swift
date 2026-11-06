import AppKit

/// Hooks for the debug harness: drive the Markdown writer and source editor.
extension MarkdownRenderer: DebugScriptable {
    func debugRun(verb: String, arg: String, window: NSWindow) async {
        switch verb {
        case "mode": mode = Int(arg) ?? mode
        case "insert": writer?.insert(arg)
        case "format": format(arg)
        case "set": replaceDocument(arg.replacingOccurrences(of: "\\n", with: "\n"))
        case "key":
            // "cmd+1", "cmd+alt+t" … through the window, as a real keystroke would go.
            let parts = arg.split(separator: "+").map(String.init)
            var flags: NSEvent.ModifierFlags = []
            if parts.contains("cmd") { flags.insert(.command) }
            if parts.contains("shift") { flags.insert(.shift) }
            if parts.contains("alt") { flags.insert(.option) }
            if parts.contains("ctrl") { flags.insert(.control) }
            let ch = parts.last ?? ""
            let codes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "0": 29, "b": 11, "i": 34, "u": 32, "k": 40, "t": 17, "o": 31, "/": 44, "s": 1, "l": 37, "d": 2, "\\": 42]
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: codes[ch] ?? 0) {
                if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
            }
        case "save": saveChanges { ok in print("MD saved", ok) }
        case "find": showFind(replace: true); findBar.debugSet(find: arg, replace: "")
            if let d = findDriver { let r = await d.search(arg, step: 0); print("FIND \(r.current)/\(r.total)") }
        case "findnext":
            if let d = findDriver { let r = await d.search(arg, step: 1); print("FIND \(r.current)/\(r.total)") }
        case "replace":
            let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if let d = findDriver, p.count == 2 { let r = await d.replaceCurrent(p[0], with: p[1]); print("REPLACE \(r.current)/\(r.total)") }
        case "replaceall":
            let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if let d = findDriver, p.count == 2 { print("REPLACED \(await d.replaceAll(p[0], with: p[1]))") }
        case "writermode": toggleWriterMode(arg)
        case "status": print("STATUS", statusText)
        case "appearance":
            AppSettings.shared.appearance = AppAppearance(rawValue: arg) ?? .system
        case "js":
            let r = try? await writer?.webView.evaluateJavaScript(arg)
            print("MD js → \(String(describing: r).prefix(600))")
        default: print("MD unknown verb", verb)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let text = await documentText()
        print("MD \(verb) → mode=\(mode) dirty=\(hasUnsavedChanges) draft=\(isDraft) text=\(text.debugDescription.prefix(200))")
    }

    func debugDump() -> String { "mode=\(mode) dirty=\(hasUnsavedChanges) chars=\(currentSource.count)" }
}
