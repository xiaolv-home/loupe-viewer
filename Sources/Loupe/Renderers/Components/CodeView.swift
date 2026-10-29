import AppKit
import LoupeCore
import LoupeObjC

/// Gutter with line numbers for a TextKit 1 NSTextView. Only logical lines are numbered,
/// wrapped continuation fragments stay blank.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var lineStarts: [Int] = [0] { didSet { updateThickness(); needsDisplay = true } }
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }
    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let w = CGFloat(digits) * 6.6 + 26
        if abs(ruleThickness - w) > 0.5 { ruleThickness = w }
    }

    override var requiredThickness: CGFloat { ruleThickness }

    func line(forCharacter idx: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= idx { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.sheet.setFill()
        bounds.fill()

        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let length = (tv.string as NSString).length
        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin
        let glyphRange = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]
        let selected = tv.selectedRange().location
        let selectedLine = line(forCharacter: selected)
        var i = line(forCharacter: charRange.location)
        let end = NSMaxRange(charRange)
        while i < lineStarts.count {
            let c = lineStarts[i]
            if c > end { break }
            var lineRect: NSRect
            if c >= length {
                lineRect = lm.extraLineFragmentRect
                if lineRect.isEmpty { break }
            } else {
                lineRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: c), effectiveRange: nil, withoutAdditionalLayout: true)
            }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: tv).y
            let label = "\(i + 1)" as NSString
            var a = attrs
            if i == selectedLine { a[.foregroundColor] = Theme.emberNS }
            let size = label.size(withAttributes: a)
            let baselineOffset = (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 4, y: y + max(0, baselineOffset)), withAttributes: a)
            i += 1
        }
    }
}

/// Scrollable, selectable, searchable source view with gutter, wrapping and highlighting.
final class CodeView: NSView {
    let scrollView = NSScrollView()
    let textView: NSTextView
    private var ruler: LineNumberRuler!
    private var highlightTask: Task<Void, Never>?
    private(set) var lineCount = 0
    private(set) var highlighted = false

    var wrap: Bool = true { didSet { applyWrap() } }

    override init(frame: NSRect) {
        textView = NSTextView(usingTextLayoutManager: false)
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = Theme.codeBackground
        textView.textContainerInset = NSSize(width: 14, height: 20)
        textView.font = Theme.codeFont
        textView.textColor = Theme.ink
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.backgroundLayoutEnabled = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.18
        ps.tabStops = []
        ps.defaultTabInterval = 4 * 7.5
        textView.defaultParagraphStyle = ps
        textView.typingAttributes = [.font: Theme.codeFont, .foregroundColor: Theme.ink, .paragraphStyle: ps]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.codeBackground
        scrollView.findBarPosition = .aboveContent
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSTextView.didChangeSelectionNotification, object: textView)
        applyWrap()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged() { ruler?.needsDisplay = true }

    var showsLineNumbers: Bool = true {
        didSet { scrollView.rulersVisible = showsLineNumbers }
    }

    private func applyWrap() {
        guard let tc = textView.textContainer else { return }
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            tc.widthTracksTextView = false
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        ruler?.needsDisplay = true
    }

    /// Replaces the content. Line indexing and highlighting run off the main thread.
    func setText(_ text: String, language: String?, highlight: Bool) async {
        highlightTask?.cancel()
        highlighted = false
        let attrs = textView.typingAttributes
        let ns = text as NSString
        let starts = await Task.detached(priority: .userInitiated) { CodeView.lineStarts(ns) }.value
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.lineCount = starts.count
            let storage = NSTextStorage(string: text, attributes: attrs)
            self.textView.layoutManager?.replaceTextStorage(storage)
            self.ruler.lineStarts = starts
            self.textView.scrollToBeginningOfDocument(nil)
            self.textView.setSelectedRange(NSRange(location: 0, length: 0))
        }

        guard highlight, let lang = language, let hl = SyntaxHighlighter.forLanguage(lang) else { return }
        highlightTask = Task { [weak self] in
            let tokens = await Task.detached(priority: .utility) { () -> [Token] in
                hl.tokens(in: text, isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyHighlight(tokens, resetBaseFont: false)
            }
        }
    }

    nonisolated static func lineStarts(_ ns: NSString) -> [Int] {
        var starts: [Int] = [0]
        let len = ns.length
        guard len > 0 else { return starts }
        let chunk = 1 << 16
        var buf = [unichar](repeating: 0, count: chunk)
        var pos = 0
        while pos < len {
            let n = min(chunk, len - pos)
            ns.getCharacters(&buf, range: NSRange(location: pos, length: n))
            for i in 0..<n where buf[i] == 10 { starts.append(pos + i + 1) }
            pos += n
        }
        return starts
    }

    func cancel() {
        highlightTask?.cancel()
        editTimer?.invalidate()
    }

    // MARK: Editing

    private var editLanguage: String?
    private var editTimer: Timer?
    /// Called (debounced) with the new text after the user edits it.
    var onEdit: ((String) -> Void)?

    /// Turns the view into an editor: undo, live re-highlighting and line numbers that follow.
    func makeEditable(language: String?) {
        editLanguage = language
        textView.isEditable = true
        textView.allowsUndo = true
        textView.delegate = self
        textView.insertionPointColor = Theme.emberNS
    }

    /// Re-highlights and re-numbers shortly after typing pauses (typing itself stays light).
    fileprivate func textEdited() {
        let text = textView.string
        ruler.lineStarts = CodeView.lineStarts(text as NSString)
        lineCount = ruler.lineStarts.count
        editTimer?.invalidate()
        editTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = self.textView.string
                self.onEdit?(current)
                self.rehighlight(current)
            }
        }
    }

    private func rehighlight(_ text: String) {
        guard let lang = editLanguage, let hl = SyntaxHighlighter.forLanguage(lang),
              text.utf8.count <= AppSettings.shared.highlightLimitBytes else { return }
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            let tokens = await Task.detached(priority: .utility) { () -> [Token] in
                hl.tokens(in: text, isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.textView.string == text else { return }
                self.applyHighlight(tokens, resetBaseFont: true)
            }
        }
    }

    /// TextKit updates. Call on the main thread.
    private func applyHighlight(_ tokens: [Token], resetBaseFont: Bool) {
        guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let valid = tokens.filter { NSMaxRange($0.range) <= storage.length }
        let base = textView.font ?? Theme.codeFont
        let bold = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .semibold)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        // Weight/italic live in the storage; colour as temporary attributes (no relayout).
        // The two must not be interleaved: temporary attributes may not change mid-edit.
        _ = LPTry({
            storage.beginEditing()
            if resetBaseFont { storage.addAttribute(.font, value: base, range: full) }
            for t in valid {
                if Theme.syntaxIsBold(t.kind) { storage.addAttribute(.font, value: bold, range: t.range) }
                else if t.kind == .comment { storage.addAttribute(.font, value: italic, range: t.range) }
            }
            storage.endEditing()
        }, nil)
        _ = LPTry({
            if resetBaseFont { lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full) }
            for t in valid {
                lm.addTemporaryAttribute(.foregroundColor, value: Theme.syntax(t.kind), forCharacterRange: t.range)
            }
        }, nil)
        highlighted = true
    }

    /// ⌘B / ⌘I: wraps the selection in ** or *, or unwraps it when it already has that style.
    /// Bold and italic combine (***text***) and come off independently.
    func toggleWrap(_ marker: String) {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        func stars(from i: Int, step: Int) -> Int {
            var n = 0, j = i
            while j >= 0, j < ns.length, ns.character(at: j) == 42 { n += 1; j += step }
            return n
        }
        let around = min(stars(from: sel.location - 1, step: -1), stars(from: NSMaxRange(sel), step: 1))
        let width = (marker as NSString).length
        let has = width == 2 ? around >= 2 : (around == 1 || around == 3)
        let inner = ns.substring(with: sel)
        if has {
            replace(NSRange(location: sel.location - width, length: sel.length + 2 * width), with: inner,
                    select: NSRange(location: sel.location - width, length: sel.length))
        } else {
            replace(sel, with: marker + inner + marker, select: NSRange(location: sel.location + width, length: sel.length))
        }
    }

    /// ⌘K: the selection becomes link text, with the address selected for typing.
    func insertLink() {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let label = sel.length > 0 ? ns.substring(with: sel) : "链接文字"
        let text = "[\(label)](https://)"
        let urlStart = sel.location + (label as NSString).length + 3
        replace(sel, with: text, select: NSRange(location: urlStart, length: 8))
    }

    /// ⌘B bold, ⌘I italic, ⌘K link while editing (views get key equivalents before the menu,
    /// so these win over ⌘I「显示简介」only inside the editor).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard textView.isEditable, window?.firstResponder === textView,
              e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers {
        case "b": toggleWrap("**"); return true
        case "i": toggleWrap("*"); return true
        case "k": insertLink(); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    /// Replaces text as one undoable step (used by the AI's edits).
    func replaceText(in range: NSRange, with text: String) {
        replace(range, with: text, select: NSRange(location: range.location + (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(NSRange(location: range.location, length: (text as NSString).length))
    }

    /// An undoable replacement through the text view (as if typed).
    private func replace(_ range: NSRange, with text: String, select: NSRange) {
        textView.breakUndoCoalescing()          // a formatting step undoes on its own
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
        textView.didChangeText()
        textView.setSelectedRange(select)
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        window?.makeFirstResponder(textView)
        textView.performTextFinderAction(item)
    }

    func findNext(_ forward: Bool) {
        let item = NSMenuItem()
        item.tag = (forward ? NSTextFinder.Action.nextMatch : NSTextFinder.Action.previousMatch).rawValue
        textView.performTextFinderAction(item)
    }

    func zoom(by delta: CGFloat) {
        let size = max(8, min(36, (textView.font?.pointSize ?? 12.5) + delta))
        setFontSize(size)
    }

    func setFontSize(_ size: CGFloat) {
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        textView.font = f
        textView.typingAttributes[.font] = f
        ruler.needsDisplay = true
    }
}

extension CodeView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { textEdited() }
}

