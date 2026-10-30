import Foundation

/// Path checks shared by the web viewer and the AI tools. Pure logic so the rules can be
/// tested without AppKit. Symlinks are resolved before the check: a link inside an allowed
/// folder must not be treated as if it still lived there.
public enum FileAccessPolicy {
    /// `path` is `root` or a descendant. A sibling whose name merely starts with `root`
    /// (`/tmp/web` vs `/tmp/web-secret`) does not count.
    public static func contains(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// File URL the page may read, after symlink resolution. `nil` when it leaves `root`.
    public static func fileInsideRoot(_ file: URL, root: URL) -> URL? {
        let rootReal = root.resolvingSymlinksInPath().standardizedFileURL
        let fileReal = file.resolvingSymlinksInPath().standardizedFileURL
        guard contains(fileReal.path, root: rootReal.path) else { return nil }
        return fileReal
    }

    /// Bundled asset under `root`. `relativePath` is the URL path (`/vendor/a.js` or `vendor/a.js`).
    public static func bundledFile(root: URL, relativePath: String) -> URL? {
        let rootURL = root.standardizedFileURL
        let joined = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard contains(joined.path, root: rootURL.path) else { return nil }
        return joined
    }

    /// Loopback only: localhost and 127.0.0.0/8 and ::1. Private LAN addresses are not loopback.
    public static func isLoopback(host: String?) -> Bool {
        guard var h = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("["), h.hasSuffix("]"), h.count >= 2 {
            h = String(h.dropFirst().dropLast())
        }
        if h == "localhost" || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        for part in parts {
            guard let n = Int(part), (0...255).contains(n) else { return false }
        }
        return true
    }

    public static func isLoopback(url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        return isLoopback(host: url.host)
    }

    /// `nil` when the model may read this file. Skill folders are allowed even under ~/Library.
    public static func readDenial(_ url: URL, home: URL, skillRoots: [URL]) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        for root in skillRoots {
            let skill = root.resolvingSymlinksInPath().standardizedFileURL.path
            if contains(path, root: skill) { return nil }
        }
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        if contains(path, root: homePath) {
            let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
            let rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
            let parts = rel.split(separator: "/").map(String.init)
            if let hidden = parts.first(where: { $0.hasPrefix(".") }) {
                return "出于安全，不读取 ~/\(hidden) 里的内容（可能含密码或应用数据）"
            }
            if parts.first == "Library" {
                return "出于安全，不读取 ~/Library 里的内容（可能含密码或应用数据）"
            }
        }
        if isSystemPath(path) { return "不读取系统文件" }
        return nil
    }

    /// `nil` when the model may write here: inside the home folder (not Library, not dot-folders) or /tmp.
    public static func writeDenial(_ url: URL, home: URL) -> String? {
        let lexical = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        if isTemporary(lexical) || isTemporary(resolved) { return nil }
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        guard contains(resolved, root: homePath), resolved != homePath else { return "只能写到你的个人文件夹里" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        let rel = String(resolved.dropFirst(prefix.count))
        let parts = rel.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) || parts.first == "Library" {
            return "不写入隐藏文件夹或 ~/Library"
        }
        return nil
    }

    private static func isTemporary(_ path: String) -> Bool {
        path == "/tmp" || path.hasPrefix("/tmp/") || path == "/private/tmp" || path.hasPrefix("/private/tmp/")
    }

    private static func isSystemPath(_ path: String) -> Bool {
        if path == "/System" || path.hasPrefix("/System/") { return true }
        if path == "/etc" || path.hasPrefix("/etc/") { return true }
        if path == "/private/etc" || path.hasPrefix("/private/etc/") { return true }
        return false
    }
}
