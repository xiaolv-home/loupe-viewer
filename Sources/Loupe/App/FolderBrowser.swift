import AppKit

/// The sidebar's folder: where you are, what is in it (folders first), and how you got there.
/// It follows the open file, but you can walk up and into other folders without opening anything.
@MainActor
final class FolderBrowser: ObservableObject {
    struct Item: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var dir: URL?
    @Published private(set) var items: [Item] = []
    private static let lastDirKey = "lastBrowseDir"

    init() {
        let last = UserDefaults.standard.string(forKey: Self.lastDirKey).map { URL(fileURLWithPath: $0) }
        let start = last.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if let start { show(start) }
    }

    /// Shows the folder holding a file that was just opened.
    func reveal(_ file: URL) {
        let d = file.deletingLastPathComponent().standardizedFileURL
        if d != dir { show(d) }
    }

    func show(_ folder: URL) {
        let d = folder.standardizedFileURL
        dir = d
        if !AppEnvironment.isScripted { UserDefaults.standard.set(d.path, forKey: Self.lastDirKey) }
        reload()
    }

    func reload() {
        guard let d = dir else { return }
        let showHidden = AppSettings.shared.showHiddenSiblings
        // Local folders list instantly (no blank moment); network ones off the main thread.
        if (try? d.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
            items = Self.list(d, showHidden: showHidden)
            return
        }
        Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) { Self.list(d, showHidden: showHidden) }.value
            guard let self, self.dir == d else { return }
            self.items = list
        }
    }

    var parent: URL? {
        guard let d = dir, d.path != "/" else { return nil }
        return d.deletingLastPathComponent()
    }

    func goUp() { if let p = parent { show(p) } }

    /// The folder and every folder above it, innermost first (for the path menu).
    var ancestry: [URL] {
        var out: [URL] = []
        var cur = dir
        while let c = cur {
            out.append(c)
            if c.path == "/" { break }
            cur = c.deletingLastPathComponent()
        }
        return out
    }

    /// Home, Desktop, Downloads, Documents and the folders of recently opened files.
    static var places: [(title: String, url: URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = [("个人", fm.homeDirectoryForCurrentUser)]
        for (t, d) in [("桌面", FileManager.SearchPathDirectory.desktopDirectory), ("下载", .downloadsDirectory), ("文稿", .documentDirectory)] {
            if let u = fm.urls(for: d, in: .userDomainMask).first { out.append((t, u)) }
        }
        return out
    }

    static var recentFolders: [URL] {
        var seen = Set<String>()
        return RecentFiles.all().map { $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }.prefix(6).map { $0 }
    }

    /// Folders first, then files and packages (iWork documents open as files), by name.
    nonisolated static func list(_ dir: URL, showHidden: Bool) -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                       options: showHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        let items = urls.map { u -> Item in
            let rv = try? u.resourceValues(forKeys: Set(keys))
            return Item(url: u.standardizedFileURL, isFolder: rv?.isDirectory == true && rv?.isPackage != true)
        }
        return items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
