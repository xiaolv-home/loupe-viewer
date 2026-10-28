import AppKit
import SwiftUI
import PDFKit
import LoupeCore
import LoupeObjC
import Quartz

/// PDFView that never follows external links on its own.
final class SafePDFView: PDFView {
    /// Set by the renderer: scroll to page 1 on the first layout with a real size.
    var pendingInitialPage = false
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    override func layout() {
        super.layout()
        if pendingInitialPage, bounds.width > 50, let first = document?.page(at: 0) {
            pendingInitialPage = false
            DispatchQueue.main.async { self.go(to: first) }
        }
    }
}

/// Outline (bookmarks) list backed by PDFOutline.
final class OutlineList: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    var root: PDFOutline? { didSet { outline.reloadData(); expandTop() } }
    var onSelect: ((PDFOutline) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("t"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .small
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        let s = NSScrollView()
        s.documentView = outline
        s.drawsBackground = false
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func expandTop() {
        guard let r = root else { return }
        for i in 0..<r.numberOfChildren { if let c = r.child(at: i), c.isOpen { outline.expandItem(c) } }
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? root)?.numberOfChildren ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? root)?.child(at: index) ?? PDFOutline()
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }
    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        let t = (o.makeView(withIdentifier: .init("c"), owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = .init("c")
            t.lineBreakMode = .byTruncatingTail
            t.font = .systemFont(ofSize: 12)
            return t
        }()
        t.stringValue = (item as? PDFOutline)?.label ?? ""
        return t
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        if let o = outline.item(atRow: outline.selectedRow) as? PDFOutline { onSelect?(o) }
    }
}
