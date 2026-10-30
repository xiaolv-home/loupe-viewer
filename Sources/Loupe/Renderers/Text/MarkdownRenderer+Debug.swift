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
            let codes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "0": 29, "b": 11, "i": 34, "u": 32, "k": 40, "t": 17, "o": 31, "/": 44, "s": 1]
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: codes[ch] ?? 0) {
                if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
            }
        case "save": saveChanges { ok in print("MD saved", ok) }
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
