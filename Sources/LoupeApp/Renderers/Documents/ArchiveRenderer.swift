import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LoupeCore

/// Node in an archive or folder tree. Folder nodes may load their children lazily.
final class FileNode {
    let name: String
    let isDirectory: Bool
    var size: Int64?
    var modified: Date?
    var encrypted = false
    var isSymlink = false
    private var _children: [FileNode]?
    private var loader: (() -> [FileNode])?
    var childMap: [String: FileNode] = [:]

    init(name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil, loader: (() -> [FileNode])? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.loader = loader
        if isDirectory && loader == nil { _children = [] }
    }

    var children: [FileNode] {
        if let c = _children { return c }
        let c = loader?() ?? []
        _children = c
        loader = nil
        return c
    }

    func add(_ n: FileNode) {
        _children = (_children ?? []) + [n]
        childMap[n.name] = n
    }

    func sortRecursively() {
        guard var c = _children else { return }
        c.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        _children = c
        c.forEach { $0.sortRecursively() }
    }

    @discardableResult
    func totalSize() -> Int64 {
        guard isDirectory, let c = _children else { return size ?? 0 }
        let s = c.reduce(Int64(0)) { $0 + $1.totalSize() }
        size = s
        return s
    }

    static func tree(from entries: [ArchiveEntry]) -> FileNode {
        let root = FileNode(name: "/", isDirectory: true)
        for e in entries {
            let parts = e.path.split(separator: "/").map(String.init).filter { $0 != "." }
            guard !parts.isEmpty else { continue }
            var cur = root
            for (i, p) in parts.enumerated() {
                let last = i == parts.count - 1
                if let existing = cur.childMap[p] {
                    cur = existing
                    if last && !e.isDirectory { cur.size = e.size; cur.modified = e.modified }
                    continue
                }
                let node = FileNode(name: p, isDirectory: !last || e.isDirectory,
                                    size: last && !e.isDirectory ? e.size : nil,
                                    modified: last ? e.modified : nil)
                if last { node.encrypted = e.isEncrypted; node.isSymlink = e.isSymlink }
                cur.add(node)
                cur = node
            }
        }
        root.sortRecursively()
        root.totalSize()
        return root
    }
}

/// Outline listing name / size / modified / kind for a FileNode tree.
final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    let root: FileNode
    var onOpen: ((FileNode) -> Void)?
    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    init(root: FileNode) {
        self.root = root
        super.init(frame: .zero)
        for (id, title, w) in [("n", "名称", 360.0), ("s", "大小", 90.0), ("d", "修改日期", 140.0), ("k", "种类", 140.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            c.minWidth = 50
            c.headerCell.font = .systemFont(ofSize: 10.5, weight: .semibold)
            if id == "s" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
            if id == "n" { outline.outlineTableColumn = c }
        }
        outline.style = .plain
        outline.rowHeight = 22
        outline.backgroundColor = Theme.sheet
        outline.usesAlternatingRowBackgroundColors = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let s = NSScrollView()
        s.documentView = outline
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.backgroundColor = Theme.sheet
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        outline.reloadData()
        // A single top-level folder (typical "project.zip/project/") is opened right away.
        if root.children.count == 1, let only = root.children.first, only.isDirectory { outline.expandItem(only) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func detach() { outline.dataSource = nil; outline.delegate = nil }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? FileNode) ?? root).children.count }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? FileNode) ?? root).children[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory ?? false }

    @objc private func doubleClicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if n.isDirectory { outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n) }
        else { onOpen?(n) }
    }

    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode, let id = col?.identifier.rawValue else { return nil }
        if id == "n" {
            let cell = (o.makeView(withIdentifier: .init("name"), owner: nil) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                v.identifier = .init("name")
                let iv = NSImageView()
                let t = NSTextField(labelWithString: "")
                t.lineBreakMode = .byTruncatingMiddle
                t.font = .systemFont(ofSize: 12)
                for x in [iv, t] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
                v.imageView = iv
                v.textField = t
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                    t.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6), t.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                    t.centerYAnchor.constraint(equalTo: v.centerYAnchor)
                ])
                return v
            }()
            cell.textField?.stringValue = n.name + (n.encrypted ? "  🔒" : "")
            let ext = (n.name as NSString).pathExtension
            cell.imageView?.image = n.isDirectory ? NSWorkspace.shared.icon(for: .folder)
                : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
            return cell
        }
        let t = (o.makeView(withIdentifier: .init(id), owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = .init(id)
            t.lineBreakMode = .byTruncatingTail
            return t
        }()
        t.textColor = .secondaryLabelColor
        switch id {
        case "s":
            t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            t.alignment = .right
            t.stringValue = n.size.map { Fmt.bytes($0) } ?? "—"
        case "d":
            t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            t.stringValue = n.modified.map { dateFmt.string(from: $0) } ?? "—"
        default:
            t.font = .systemFont(ofSize: 11)
            if n.isDirectory { t.stringValue = "文件夹" }
            else {
                let ext = (n.name as NSString).pathExtension
                t.stringValue = UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "文件" : ext.uppercased())
            }
        }
        return t
    }
}

private struct TreeHeader: View {
    let title: String
    let detail: String
    let note: String?
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.ember) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }
}

private func stack(header: NSView, body: NSView) -> NSView {
    let v = NSView()
    for x in [header, body] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
    NSLayoutConstraint.activate([
        header.topAnchor.constraint(equalTo: v.topAnchor), header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        body.topAnchor.constraint(equalTo: header.bottomAnchor), body.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        body.trailingAnchor.constraint(equalTo: v.trailingAnchor), body.bottomAnchor.constraint(equalTo: v.bottomAnchor)
    ])
    return v
}

/// Lists archive contents through libarchive without extracting anything.
@MainActor
final class ArchiveRenderer: Renderer {
    static let engineName = "libarchive"
    static func canHandle(_ file: FileContext) -> Bool { !file.isDirectory }

    private var tree: FileTreeView?
    private var listing: ArchiveListing?
    private var fileCount = 0
    private var dirCount = 0

    required init() {}

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        let url = file.url
        host.reportProgress(nil, label: "正在读取目录…")
        let l: ArchiveListing
        do {
            l = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveReader.list(url: url, progress: { n in
                        Task { @MainActor in host.reportProgress(nil, label: "正在读取目录… \(n) 项") }
                    }, isCancelled: { Task.isCancelled })
                }.value
            } onCancel: {}
        } catch ArchiveError.cancelled {
            throw RenderError.cancelled
        } catch {
            throw RenderError.unreadable((error as? LocalizedError)?.errorDescription ?? "无法读取压缩包")
        }
        try Task.checkCancellation()
        listing = l
        fileCount = l.entries.filter { !$0.isDirectory }.count
        dirCount = l.entries.count - fileCount
        let root = FileNode.tree(from: l.entries)
        let t = FileTreeView(root: root)
        tree = t
        var note: String?
        if l.truncated { note = "条目过多，仅列出前 \(Fmt.number(ArchiveReader.maxEntries)) 项" }
        else if l.errorMessage != nil { note = "部分内容无法读取（可能已损坏或加密）" }
        else if l.entries.contains(where: { $0.isEncrypted }) { note = "包含加密条目" }
        let header = NSHostingView(rootView: TreeHeader(title: l.formatName.uppercased() + (l.filterName.isEmpty ? "" : " · \(l.filterName)"),
                                                        detail: "\(Fmt.number(fileCount)) 个文件 · 解压后约 \(Fmt.bytes(root.size ?? 0))",
                                                        note: note))
        header.sizingOptions = [.intrinsicContentSize]
        return stack(header: header, body: t)
    }

    func cleanup() { tree?.detach(); tree = nil }

    var statusText: String { "\(Fmt.number(fileCount)) 个文件 · \(Fmt.number(dirCount)) 个文件夹" }
    var infoSections: [InfoSection] {
        guard let l = listing else { return [] }
        var items = [InfoItem("格式", l.formatName), InfoItem("文件", Fmt.number(fileCount)), InfoItem("文件夹", Fmt.number(dirCount)),
                     InfoItem("解压后大小", Fmt.bytes(tree?.root.size ?? 0))]
        if !l.filterName.isEmpty { items.insert(InfoItem("压缩", l.filterName), at: 1) }
        if let e = l.errorMessage { items.append(InfoItem("警告", e)) }
        return [InfoSection("压缩包", items)]
    }
    var initialFirstResponder: NSView? { tree?.outline }
}

/// Folders (and non-document packages) are shown as a browsable tree; double-click opens a file.
@MainActor
final class DirectoryRenderer: Renderer {
    static let engineName = "Folder"
    static func canHandle(_ file: FileContext) -> Bool { file.isDirectory }

    private var tree: FileTreeView?
    private var count = 0

    required init() {}

    nonisolated static func children(of url: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.map { u in
            let rv = try? u.resourceValues(forKeys: Set(keys))
            let dir = (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
            return FileNode(name: u.lastPathComponent, isDirectory: dir, size: rv?.fileSize.map(Int64.init), modified: rv?.contentModificationDate,
                            loader: dir ? { DirectoryRenderer.children(of: u) } : nil)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        let url = file.url
        let kids = await Task.detached { DirectoryRenderer.children(of: url) }.value
        count = kids.count
        let root = FileNode(name: url.lastPathComponent, isDirectory: true, loader: { kids })
        let t = FileTreeView(root: root)
        t.onOpen = { [weak host] n in
            // Resolve the node's path by walking the outline parents.
            var parts = [n.name]
            var item: Any? = t.outline.parent(forItem: n)
            while let p = item as? FileNode { parts.insert(p.name, at: 0); item = t.outline.parent(forItem: p) }
            host?.open(parts.reduce(url) { $0.appendingPathComponent($1) })
        }
        tree = t
        let header = NSHostingView(rootView: TreeHeader(title: url.lastPathComponent, detail: "\(count) 项 · 双击文件即可查看", note: nil))
        header.sizingOptions = [.intrinsicContentSize]
        return stack(header: header, body: t)
    }

    func cleanup() { tree?.detach(); tree = nil }
    var statusText: String { "\(count) 项" }
    var initialFirstResponder: NSView? { tree?.outline }
}
