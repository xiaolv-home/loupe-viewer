import AppKit

/// File icons come from the system on each request, which is too slow to repeat on every redraw.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let known = cache.object(forKey: key) { return known }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
