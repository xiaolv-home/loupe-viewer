import Foundation

/// Tidies up after the app's rename from Loupe, the first time it runs under the new name.
///
/// The bundle identifier deliberately stays `app.loupe.viewer`. The system files recent documents,
/// default-app choices and file access grants under it, and none of those can be carried to a new
/// identifier. What has the old name in it, and can move, is the settings keys holding window
/// positions and the folder with API keys, conversations and drafts.
enum LegacyData {
    private static let bundleID = "app.loupe.viewer"
    private static let doneKey = "tidiedAfterRename"
    private static let automationFlags: Set<String> = ["--snapshot", "--cmd", "--probe", "--stress", "--purge-recents"]

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier == bundleID, !defaults.bool(forKey: doneKey),
            automationFlags.isDisjoint(with: CommandLine.arguments)
        else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("Loupe", isDirectory: true)
        let newFolder = support.appendingPathComponent("Perlustra", isDirectory: true)

        let current = defaults.persistentDomain(forName: bundleID) ?? [:]
        let updated = converted(current, from: oldFolder.path, to: newFolder.path)
        for key in current.keys where updated[key] == nil { defaults.removeObject(forKey: key) }
        for (key, value) in updated { defaults.set(value, forKey: key) }

        // Tried again next launch if something could not be moved, so nothing is left behind silently.
        if moveContents(of: oldFolder, into: newFolder) {
            try? FileManager.default.removeItem(at: oldFolder.appendingPathComponent(".DS_Store"))
            if (try? FileManager.default.contentsOfDirectory(atPath: oldFolder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: oldFolder)
            }
            defaults.set(true, forKey: doneKey)
        }
    }

    /// Settings under their new names: window and panel positions are stored under keys holding the
    /// app's name, and recent files can point into the folder that is moving.
    static func converted(_ old: [String: Any], from oldFolder: String, to newFolder: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in old {
            let name = key.replacingOccurrences(of: "Loupe", with: "Perlustra")
            switch value {
            case let path as String: out[name] = path.replacingOccurrences(of: oldFolder, with: newFolder)
            case let paths as [String]: out[name] = paths.map { $0.replacingOccurrences(of: oldFolder, with: newFolder) }
            default: out[name] = value
            }
        }
        return out
    }

    /// Moves each item of a folder into another, leaving anything already at the destination alone.
    /// Returns false if an item could not be moved; one that already exists there counts as handled.
    @discardableResult
    static func moveContents(of old: URL, into new: URL, using files: FileManager = .default) -> Bool {
        guard files.fileExists(atPath: old.path) else { return true }
        guard let items = try? files.contentsOfDirectory(at: old, includingPropertiesForKeys: nil),
            (try? files.createDirectory(at: new, withIntermediateDirectories: true)) != nil
        else { return false }
        var complete = true
        for item in items {
            let target = new.appendingPathComponent(item.lastPathComponent)
            guard !files.fileExists(atPath: target.path) else {
                if isFolder(item, files), isFolder(target, files) { complete = moveContents(of: item, into: target, using: files) && complete }
                continue
            }
            do { try files.moveItem(at: item, to: target) } catch { complete = false }
        }
        return complete
    }

    private static func isFolder(_ url: URL, _ files: FileManager) -> Bool {
        var folder: ObjCBool = false
        return files.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }
}
