import AppKit

/// Hooks for the debug harness: drive the Markdown editor with real key events.
extension MarkdownRenderer: DebugScriptable {
    func debugRun(verb: String, arg: String, window: NSWindow) async {
        let tv = code?.textView
        switch verb {
        case "type": tv?.insertText(arg, replacementRange: tv?.selectedRange() ?? NSRange(location: 0, length: 0))
        case "select":
            let n = arg.split(separator: ",").compactMap { Int($0) }
            if n.count == 2 { tv?.setSelectedRange(NSRange(location: n[0], length: n[1])) }
            if arg == "end", let tv { tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
        case "key":
            // "cmd+b" etc. through the window, as a real keystroke would go.
            let parts = arg.split(separator: "+").map(String.init)
            var flags: NSEvent.ModifierFlags = []
            if parts.contains("cmd") { flags.insert(.command) }
            if parts.contains("shift") { flags.insert(.shift) }
            let ch = parts.last ?? ""
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: 0) {
                if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }   // what NSApp does for the key window
            }
        case "undo": window.undoManager?.undo()
        case "save": saveChanges { ok in print("MD saved", ok) }
        default: print("MD unknown verb", verb)
        }
        try? await Task.sleep(nanoseconds: 450_000_000)     // let the debounced preview catch up
        let preview = ((try? await web?.evaluateJavaScript("document.getElementById('doc').innerHTML.slice(0, 400)")) as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        print("MD \(verb) → fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") dirty=\(hasUnsavedChanges) mode=\(mode) text=\(currentSource.debugDescription.prefix(160)) | preview=\(preview.prefix(200))")
    }

    func debugDump() -> String { "mode=\(mode) dirty=\(hasUnsavedChanges) chars=\(currentSource.count)" }
}
