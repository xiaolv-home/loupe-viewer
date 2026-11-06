import AppKit
import Foundation

/// The files opened lately: Loupe's own list merged with the system's Open Recent.
enum RecentFiles {
    static let didChange = Notification.Name("LoupeRecentFilesDidChange")
    private static let key = "recentFiles"

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(30)), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Forgets recent files inside `folder` (both Loupe's list and the system's Open Recent).
    @MainActor
    static func purge(under folder: URL) {
        let prefix = folder.standardizedFileURL.path + "/"
        forget { $0.standardizedFileURL.path.hasPrefix(prefix) }
    }

    /// Takes one file off the list. The file itself is not touched.
    @MainActor
    static func remove(_ url: URL) {
        forget { $0.path == url.path }
    }

    @MainActor
    private static func forget(where matches: (URL) -> Bool) {
        let own = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { !matches(URL(fileURLWithPath: $0)) }
        UserDefaults.standard.set(own, forKey: key)
        let documents = NSDocumentController.shared
        let keep = documents.recentDocumentURLs.filter { !matches($0) }
        documents.clearRecentDocuments(nil)
        for url in keep.reversed() { documents.noteNewRecentDocumentURL(url) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    @MainActor
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NSDocumentController.shared.clearRecentDocuments(nil)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Every file on the list, whether or not it is still there. Automated runs never see the real
    /// list, which holds the names of the user's files: they get what LOUPE_RECENTS names, if anything.
    @MainActor
    static func listed() -> [URL] {
        if AppEnvironment.isScripted {
            let paths = ProcessInfo.processInfo.environment["LOUPE_RECENTS"]?.split(separator: ":") ?? []
            return paths.map { URL(fileURLWithPath: String($0)) }
        }
        let own = (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return (own + NSDocumentController.shared.recentDocumentURLs).filter { seen.insert($0.path).inserted }
    }

    /// Every file on the list that is still there, for menus. Checks the disk on the calling thread.
    @MainActor
    static func all() -> [URL] {
        listed().filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Those on the list that still exist. Checks the disk, so call it off the main thread.
    static func details(of urls: [URL]) -> [RecentFile] {
        urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else { return nil }
            return RecentFile(url: url, modified: values.contentModificationDate)
        }
    }

    /// The files whose name or folder holds every word typed, in any case.
    static func matching(_ files: [RecentFile], query: String) -> [RecentFile] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return files }
        return files.filter { file in
            let text = file.url.path.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

struct RecentFile: Identifiable, Hashable, Sendable {
    let url: URL
    let modified: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var folderName: String { url.deletingLastPathComponent().lastPathComponent }
    var typeToken: String { url.pathExtension.uppercased() }
    var folderPath: String { url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    /// A date as short as it can be while still clear: the time today, otherwise the day.
    static func timeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let clock = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天 \(clock)" }
        let day = "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return day }
        return "\(calendar.component(.year, from: date))年\(day)"
    }
}
