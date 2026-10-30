import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LoupeCore

/// Folder browser: walk up and into folders; clicking a file opens it in a tab.
/// Keyboard: ↑↓ move, Return / → open, ← up a folder.
struct SidebarView: View {
    @ObservedObject var tabs: TabList
    @ObservedObject var browser: FolderBrowser
    var body: some View { SidebarContent(model: tabs.current, browser: browser) }
}

private struct SidebarContent: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var browser: FolderBrowser
    @State private var filter = ""
    @State private var selection: URL?
    @State private var cameFrom: URL?
    /// Set while the selection is moved by code (following the open file, or the folder you came
    /// up from) so that it is not mistaken for a click.
    @State private var programmatic = false
    /// The last row opened and when, so one click reported twice (selection change and tap)
    /// opens it once.
    @State private var lastActivation: (url: URL, at: Date)?

    var filtered: [FolderBrowser.Item] {
        guard !filter.isEmpty else { return browser.items }
        return browser.items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TextField("筛选", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.bottom, 6)
            List(selection: $selection) {
                ForEach(filtered) { item in
                    SidebarRow(item: item)
                        .tag(item.url)
                        // Clicking the row that is already selected does not change the selection,
                        // so the list reports nothing: open it from the click itself.
                        .simultaneousGesture(TapGesture().onEnded {
                            if selection == item.url { activate(item.url) }
                        })
                        .contextMenu {
                            if item.isFolder {
                                Button("打开文件夹") { browser.show(item.url) }
                            } else {
                                Button("在新标签页中打开") { model.openInNewTab(item.url) }
                                Button("在当前标签页中打开") { model.open(item.url) }
                            }
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, u in
                if programmatic { programmatic = false; return }
                // A click opens; arrow keys only move the highlight (Return opens).
                guard let u, let t = NSApp.currentEvent?.type, t == .leftMouseDown || t == .leftMouseUp else { return }
                activate(u)
            }
            .onKeyPress(.return) { if let u = selection { activate(u) }; return .handled }
            .onKeyPress(.rightArrow) {
                guard let u = selection, isFolder(u) else { return .ignored }
                activate(u)
                return .handled
            }
            .onKeyPress(.leftArrow) { goUp(); return .handled }
            .overlay {
                if browser.items.isEmpty {
                    Text("这个文件夹是空的").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { select(model.file?.url) }
        .onChange(of: model.file?.url) { _, u in select(u) }
        .onChange(of: browser.dir) { _, _ in
            filter = ""
            // Going up selects the folder you came from, like Finder.
            if let c = cameFrom, browser.items.contains(where: { $0.url == c }) { select(c) } else { select(model.file?.url) }
            cameFrom = nil
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: goUp) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(browser.parent == nil)
            .help("上级文件夹（←）")
            Menu {
                Section("位置") {
                    ForEach(browser.ancestry, id: \.self) { u in
                        Button(u.path == "/" ? "磁盘" : u.lastPathComponent) { browser.show(u) }
                    }
                }
                Section("常用") {
                    ForEach(FolderBrowser.places, id: \.url) { p in Button(p.title) { browser.show(p.url) } }
                }
                let recent = FolderBrowser.recentFolders
                if !recent.isEmpty {
                    Section("最近用过的文件夹") {
                        ForEach(recent, id: \.self) { u in Button(u.lastPathComponent) { browser.show(u) } }
                    }
                }
                Divider()
                Button("选择文件夹…") { chooseFolder() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.ember).font(.system(size: 11))
                    Text(browser.dir?.lastPathComponent ?? "—").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(browser.dir?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
            Spacer(minLength: 2)
            Text("\(browser.items.count)").font(Theme.mono(10)).foregroundStyle(.secondary)
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.top, 10).padding(.bottom, 6)
    }

    private func select(_ u: URL?) {
        guard selection != u else { return }
        programmatic = true
        selection = u
    }

    private func isFolder(_ u: URL) -> Bool { browser.items.first { $0.url == u }?.isFolder == true }

    private func goUp() {
        cameFrom = browser.dir
        browser.goUp()
    }

    /// Folders open in place; files open in a tab (⌥-click: in this tab, for quick browsing).
    private func activate(_ u: URL) {
        if let last = lastActivation, last.url == u, Date().timeIntervalSince(last.at) < 0.4 { return }
        lastActivation = (u, Date())
        if isFolder(u) {
            browser.show(u)
        } else if u != model.file?.url {
            if NSEvent.modifierFlags.contains(.option) { model.open(u) } else { model.openInNewTab(u) }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = browser.dir
        p.prompt = "前往"
        if p.runModal() == .OK, let u = p.url { browser.show(u) }
    }
}

private struct SidebarRow: View {
    let item: FolderBrowser.Item
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: IconCache.icon(for: item)).resizable().frame(width: 16, height: 16)
            Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if item.isFolder {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// File icons by type (asking the system per row on every redraw makes scrolling stutter).
/// Folders with their own icon (Desktop, Downloads…) and packages keep it.
@MainActor
enum IconCache {
    private static var byKey: [String: NSImage] = [:]

    static func icon(for item: FolderBrowser.Item) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let special = item.isFolder ? item.url.path : (ext.isEmpty || ["app", "pages", "numbers", "key"].contains(ext) ? item.url.path : nil)
        let key = special ?? "ext:" + ext
        if let i = byKey[key] { return i }
        let i = special != nil ? NSWorkspace.shared.icon(forFile: item.url.path)
                               : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        if byKey.count > 2000 { byKey.removeAll() }
        byKey[key] = i
        return i
    }
}

/// The inspector for whichever tab is showing.
struct CurrentInspector: View {
    @ObservedObject var tabs: TabList
    var body: some View { InspectorView(model: tabs.current) }
}

/// Right-hand inspector with file and content metadata.
struct InspectorView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        ScrollView {
            if let f = model.file {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path))
                            .resizable().interpolation(.high).frame(width: 64, height: 64)
                        Text(f.name).font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center).lineLimit(3)
                        FormatBadge(token: f.format.token, category: f.format.family.category)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)

                    InfoBlock(section: InfoSection("文件", fileItems(f)))
                    ForEach(model.infoSections) { s in InfoBlock(section: s) }
                }
                .padding(16)
            } else {
                Text("没有打开的文件").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
    }

    func fileItems(_ f: FileContext) -> [InfoItem] {
        var items = [
            InfoItem("类型", f.format.label),
            InfoItem("大小", Fmt.bytes(f.size) + (f.size >= 1024 ? "（\(Fmt.exactBytes(f.size))）" : "")),
            InfoItem("修改时间", Fmt.date(f.modified)),
            InfoItem("创建时间", Fmt.date(f.created)),
            InfoItem("位置", f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        ]
        if let t = f.utType { items.append(InfoItem("UTI", t.identifier)) }
        let src: String
        switch f.format.source {
        case .magic: src = "文件头签名"
        case .extension: src = "扩展名"
        case .sniff: src = "内容分析"
        case .directory: src = "文件包结构"
        }
        items.append(InfoItem("识别依据", src + (f.format.extensionMismatch ? "（扩展名不符）" : "")))
        items.append(InfoItem("渲染引擎", model.engine))
        return items
    }
}

struct InfoBlock: View {
    let section: InfoSection
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: section.title)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.items) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text(item.value).font(Theme.mono(11.5)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: Theme.hairline)))
        }
    }
}
