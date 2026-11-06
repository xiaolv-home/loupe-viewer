import AppKit
import LoupeCore

/// In-place cell editor. Return commits and moves down, Tab moves right, Esc cancels.
final class CellEditor: NSTextField, NSTextFieldDelegate {
    var onFinish: ((_ text: String?, _ move: GridPoint) -> Void)?
    private var finished = false

    init(fontSize: CGFloat = 12) {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = true
        backgroundColor = Theme.sheet
        focusRingType = .none
        font = .systemFont(ofSize: fontSize)
        lineBreakMode = .byClipping
        usesSingleLineMode = true
        cell?.isScrollable = true
        wantsLayer = true
        layer?.borderWidth = 2
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.borderColor = resolved(Theme.emberNS)
    }

    private func finish(_ text: String?, _ move: GridPoint) {
        guard !finished else { return }
        finished = true
        onFinish?(text, move)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): finish(stringValue, GridPoint(row: 1, col: 0)); return true
        case #selector(NSResponder.insertTab(_:)): finish(stringValue, GridPoint(row: 0, col: 1)); return true
        case #selector(NSResponder.insertBacktab(_:)): finish(stringValue, GridPoint(row: 0, col: -1)); return true
        case #selector(NSResponder.cancelOperation(_:)): finish(nil, GridPoint(row: 0, col: 0)); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere commits without moving.
        finish(stringValue, GridPoint(row: 0, col: 0))
    }
}
