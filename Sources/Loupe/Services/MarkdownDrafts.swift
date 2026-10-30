import Foundation

/// New Markdown documents start as drafts in ~/Library/Application Support/Loupe/Drafts: they
/// save themselves as you type, and move to a real place the first time you press ⌘S.
@MainActor
enum MarkdownDrafts {
    static var root: URL {
        let base = AppEnvironment.isScripted ? FileManager.default.temporaryDirectory.appendingPathComponent("loupe-harness-drafts")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Loupe/Drafts")
        return base.standardizedFileURL
    }

    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == root.path
    }

    /// An empty 未命名 N.md.
    static func create() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Empty drafts left behind (the app quit unexpectedly) are not worth keeping.
        for f in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        where f.pathExtension == "md" && ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1) == 0 {
            try? fm.removeItem(at: f)
        }
        var n = 1
        var url = root.appendingPathComponent("未命名.md")
        while fm.fileExists(atPath: url.path) {
            n += 1
            url = root.appendingPathComponent("未命名 \(n).md")
        }
        try Data().write(to: url)
        return url
    }

    static func discard(_ url: URL) {
        guard contains(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A file name from the document: its first heading or first line.
    static func suggestedName(for text: String) -> String {
        let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var name = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        name = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\\*?\"<>|")).joined()
        return name.isEmpty ? "未命名" : String(name.prefix(40))
    }

    /// Copies the pictures the text links under assets/ from a draft's folder to the new one.
    static func moveAssets(of text: String, from: URL, to: URL) {
        let fm = FileManager.default
        guard let re = try? NSRegularExpression(pattern: #"\((assets/[^)\s]+)\)"#) else { return }
        let paths = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]).removingPercentEncoding ?? String(text[$0]) }
        }
        for p in Set(paths) {
            let src = from.appendingPathComponent(p), dst = to.appendingPathComponent(p)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: src, to: dst)
        }
    }
}
