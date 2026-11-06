import AppKit
import LoupeCore

/// Virtualised viewer for huge text files: one table row per line, decoded on demand
/// from a memory-mapped LineIndex. Search runs on raw bytes in the background.
final class LargeTextView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let index: LineIndex
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let searchStatus = NSTextField(labelWithString: "")
    private var searchBarHeight: NSLayoutConstraint!
    private var matches: [Int] = [] { didSet { matchSet = Set(matches) } }
    private var matchSet = Set<Int>()
    private var matchCursor = -1
    private var searchTask: Task<Void, Never>?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let numFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private var query = ""

    init(index: LineIndex) {
        self.index = index
        super.init(frame: .zero)

        let numCol = NSTableColumn(identifier: .init("n"))
        numCol.width = 70
        numCol.minWidth = 50
        let textCol = NSTableColumn(identifier: .init("t"))
        textCol.width = 4000
        table.addTableColumn(numCol)
        table.addTableColumn(textCol)
        table.headerView = nil
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.backgroundColor = Theme.codeBackground
        table.gridStyleMask = []
        table.style = .plain
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .noColumnAutoresizing

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = Theme.codeBackground

        searchField.placeholderString = "在整个文件中查找"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.sendsWholeSearchString = true
        searchStatus.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        searchStatus.textColor = .secondaryLabelColor
        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "上一个")!, target: self, action: #selector(prevMatch))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "下一个")!, target: self, action: #selector(nextMatch))
        let done = NSButton(title: "完成", target: self, action: #selector(hideSearch))
        for b in [prev, next, done] { b.bezelStyle = .accessoryBarAction; b.controlSize = .small }
        let stack = NSStackView(views: [searchField, searchStatus, prev, next, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(stack)
        searchBar.wantsLayer = true
        searchBar.layer?.backgroundColor = Theme.surface.cgColor
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        searchBar.isHidden = true

        for v in [searchBar, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        searchBarHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchBarHeight,
            scroll.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    var tableView: NSTableView { table }

    func reload() {
        table.reloadData()
        let digits = max(4, String(index.lineCount).count)
        table.tableColumns.first?.width = CGFloat(digits) * 7 + 14
    }

    func stop() {
        searchTask?.cancel()
        table.dataSource = nil
        table.delegate = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { index.lineCount }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = col?.identifier ?? .init("t")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.lineBreakMode = .byClipping
            t.allowsDefaultTighteningForTruncation = false
            return t
        }()
        if id.rawValue == "n" {
            cell.font = numFont
            cell.alignment = .right
            cell.textColor = matchSet.contains(row) ? Theme.emberNS : Theme.gutterText
            cell.stringValue = "\(row + 1)"
        } else {
            cell.font = font
            cell.textColor = .labelColor
            let s = index.line(row)
            if !query.isEmpty, s.localizedCaseInsensitiveContains(query) {
                let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                var r = (s as NSString).range(of: query, options: .caseInsensitive)
                while r.location != NSNotFound {
                    a.addAttribute(.backgroundColor, value: Theme.emberNS.withAlphaComponent(0.35), range: r)
                    let next = NSMaxRange(r)
                    r = (s as NSString).range(of: query, options: .caseInsensitive, range: NSRange(location: next, length: (s as NSString).length - next))
                }
                cell.attributedStringValue = a
            } else {
                cell.stringValue = s
            }
        }
        return cell
    }

    // MARK: Search

    func showSearch() {
        searchBar.isHidden = false
        searchBarHeight.constant = 38
        window?.makeFirstResponder(searchField)
    }

    @objc func hideSearch() {
        searchBar.isHidden = true
        searchBarHeight.constant = 0
        query = ""
        matches = []
        table.reloadData()
        window?.makeFirstResponder(table)
    }

    @objc private func searchSubmitted() {
        let q = searchField.stringValue
        if q == query && !matches.isEmpty { nextMatch(); return }
        runSearch(q)
    }

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        query = q
        matches = []
        matchCursor = -1
        guard !q.isEmpty else { searchStatus.stringValue = ""; table.reloadData(); return }
        searchStatus.stringValue = "搜索中…"
        let idx = index
        searchTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> [Int] in
                LargeTextView.search(idx, q, isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.matches = found
                let countText = found.count >= 100_000 ? "100000+" : String(found.count)
                self.searchStatus.stringValue = found.isEmpty ? "无结果" : "\(countText) 处"
                self.table.reloadData()
                if !found.isEmpty { self.nextMatch() }
            }
        }
    }

    /// Byte search for the query encoded the same way as the file (fast path),
    /// falling back to decoding each line for case-insensitive ASCII.
    nonisolated static func search(_ idx: LineIndex, _ q: String, isCancelled: () -> Bool) -> [Int] {
        var result: [Int] = []
        let data = idx.data
        let encodings: [Data] = [q, q.lowercased(), q.uppercased(), q.capitalized].compactMap { $0.data(using: idx.encoding.encoding) }
        var seen = Set<Int>()
        for needle in Set(encodings) where !needle.isEmpty {
            var start = data.startIndex
            while start < data.endIndex, let r = data.range(of: needle, in: start..<data.endIndex) {
                if isCancelled() { return [] }
                let line = lineFor(byte: r.lowerBound - data.startIndex, in: idx)
                if seen.insert(line).inserted { result.append(line) }
                if result.count >= 100_000 { break }
                // Skip to next line to avoid duplicates on long lines.
                if let next = idx.byteRange(ofLine: line + 1)?.lowerBound { start = data.startIndex + next } else { break }
            }
        }
        return result.sorted()
    }

    nonisolated static func lineFor(byte: Int, in idx: LineIndex) -> Int {
        var lo = 0, hi = idx.lineCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (idx.byteRange(ofLine: mid)?.lowerBound ?? Int.max) <= byte { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    @objc func nextMatch() { step(1) }
    @objc func prevMatch() { step(-1) }

    func step(_ d: Int) {
        guard !matches.isEmpty else { return }
        matchCursor = (matchCursor + d + matches.count) % matches.count
        let row = matches[matchCursor]
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        let visible = table.rows(in: table.visibleRect)
        if visible.length > 4 { table.scrollRowToVisible(min(index.lineCount - 1, row + visible.length / 2 - 1)) }
        searchStatus.stringValue = "\(matchCursor + 1) / \(matches.count)"
    }

    func controlTextDidEndEditing(_ obj: Notification) {}

    @objc func copy(_ sender: Any?) {
        let lines = table.selectedRowIndexes.prefix(100_000).map { index.line($0, maxBytes: 1 << 20) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
