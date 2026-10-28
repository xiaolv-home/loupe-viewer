import AppKit
import LoupeCore

/// Lazily expanded node over a JSONValue.
final class TreeNode {
    let key: String
    let path: String
    let value: JSONValue
    private var _children: [TreeNode]?

    init(key: String, path: String, value: JSONValue) {
        self.key = key
        self.path = path
        self.value = value
    }

    var isContainer: Bool {
        switch value { case .object, .array: return true; default: return false }
    }

    var children: [TreeNode] {
        if let c = _children { return c }
        var c: [TreeNode] = []
        switch value {
        case .object(let members):
            c = members.map { k, v in
                let safe = k.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil
                return TreeNode(key: k, path: safe ? "\(path).\(k)" : "\(path)[\"\(k)\"]", value: v)
            }
        case .array(let items):
            c = items.enumerated().map { TreeNode(key: "\($0.offset)", path: "\(path)[\($0.offset)]", value: $0.element) }
        default: break
        }
        _children = c
        return c
    }

    var preview: String {
        switch value {
        case .object(let m):
            let keys = m.prefix(4).map { $0.0 }.joined(separator: ", ")
            return "{ \(keys)\(m.count > 4 ? ", …" : "") }"
        case .array(let a): return "[ \(a.count) 项 ]"
        case .string(let s): return "\"\(s.count > 400 ? String(s.prefix(400)) + "…" : s)\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    var rawValue: String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return JSONWriter.write(value, indent: 0)
        }
    }

    var tint: TokenKind? {
        switch value {
        case .string: return .string
        case .number: return .number
        case .bool, .null: return .keyword
        default: return nil
        }
    }
}

enum JSONWriter {
    static func write(_ v: JSONValue, indent: Int, step: Int = 2) -> String {
        var out = ""
        func esc(_ s: String) -> String {
            var r = "\""
            for ch in s.unicodeScalars {
                switch ch {
                case "\"": r += "\\\""
                case "\\": r += "\\\\"
                case "\n": r += "\\n"
                case "\t": r += "\\t"
                case "\r": r += "\\r"
                default:
                    if ch.value < 0x20 { r += String(format: "\\u%04x", ch.value) } else { r.unicodeScalars.append(ch) }
                }
            }
            return r + "\""
        }
        func go(_ v: JSONValue, _ level: Int) {
            let pad = String(repeating: " ", count: (level + 1) * step)
            let close = String(repeating: " ", count: level * step)
            switch v {
            case .object(let m):
                if m.isEmpty { out += "{}"; return }
                out += "{\n"
                for (i, (k, val)) in m.enumerated() {
                    out += pad + esc(k) + ": "
                    go(val, level + 1)
                    out += i < m.count - 1 ? ",\n" : "\n"
                }
                out += close + "}"
            case .array(let a):
                if a.isEmpty { out += "[]"; return }
                out += "[\n"
                for (i, val) in a.enumerated() {
                    out += pad
                    go(val, level + 1)
                    out += i < a.count - 1 ? ",\n" : "\n"
                }
                out += close + "]"
            case .string(let s): out += esc(s)
            case .number(let n): out += n
            case .bool(let b): out += b ? "true" : "false"
            case .null: out += "null"
            }
        }
        go(v, indent)
        return out
    }
}

/// Collapsible key/value/type outline for JSON and property lists.
final class TreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    private let root: TreeNode
    private let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let typeFont = NSFont.systemFont(ofSize: 10.5)

    init(root: JSONValue, rootName: String) {
        self.root = TreeNode(key: rootName, path: "$", value: root)
        super.init(frame: .zero)
        for (id, title, width) in [("k", "键", 240.0), ("v", "值", 460.0), ("t", "类型", 110.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 60
            c.headerCell.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            outline.addTableColumn(c)
            if id == "k" { outline.outlineTableColumn = c }
        }
        outline.rowHeight = 21
        outline.style = .plain
        outline.backgroundColor = Theme.codeBackground
        outline.usesAlternatingRowBackgroundColors = false
        outline.indentationPerLevel = 16
        outline.autosaveExpandedItems = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.doubleAction = #selector(toggleItem)
        outline.target = self

        let menu = NSMenu()
        menu.addItem(withTitle: "拷贝值", action: #selector(copyValue), keyEquivalent: "").target = self
        menu.addItem(withTitle: "拷贝路径", action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: "拷贝键名", action: #selector(copyKey), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "全部展开", action: #selector(expandAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "全部折叠", action: #selector(collapseAll), keyEquivalent: "").target = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = Theme.codeBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        outline.reloadData()
        outline.expandItem(self.root)
        // Open the first level of small documents for a useful first glance.
        if self.root.children.count <= 30 {
            for c in self.root.children where c.isContainer && c.children.count <= 30 { outline.expandItem(c) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func detach() {
        outline.dataSource = nil
        outline.delegate = nil
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? TreeNode else { return 1 }
        return n.children.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? TreeNode else { return root }
        return n.children[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode)?.isContainer ?? false
    }

    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? TreeNode, let id = col?.identifier else { return nil }
        let cell = (o.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.lineBreakMode = .byTruncatingTail
            t.cell?.truncatesLastVisibleLine = true
            return t
        }()
        switch id.rawValue {
        case "k":
            cell.font = keyFont
            cell.stringValue = n.key
            cell.textColor = n === root ? .secondaryLabelColor : Theme.syntax(.key)
        case "v":
            cell.font = valueFont
            cell.stringValue = n.preview.replacingOccurrences(of: "\n", with: "⏎")
            cell.textColor = n.tint.map(Theme.syntax) ?? .tertiaryLabelColor
        default:
            cell.font = typeFont
            cell.stringValue = n.value.typeName
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }

    private var selected: TreeNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? TreeNode
    }

    private func put(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func copyValue() { if let n = selected { put(n.rawValue) } }
    @objc func copyPath() { if let n = selected { put(n.path) } }
    @objc func copyKey() { if let n = selected { put(n.key) } }
    @objc func copy(_ sender: Any?) { copyValue() }
    @objc func expandAll() { outline.expandItem(root, expandChildren: root.children.count < 2000) }
    @objc func collapseAll() { outline.collapseItem(root, collapseChildren: true); outline.expandItem(root) }
    @objc func toggleItem() {
        guard let n = outline.item(atRow: outline.clickedRow) as? TreeNode, n.isContainer else { return }
        outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n)
    }
}
