import AppKit
import Foundation
import PerlustraCore

/// The templates shipped in the app, followed by any the user keeps in their own folder.
@MainActor
enum MarkdownTemplates {
    private static var builtInFolder: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("templates"), FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/templates")
    }

    /// Markdown files put here show up under 我的模版.
    static let ownFolder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Perlustra/Templates", isDirectory: true)

    static func all() -> [MarkdownTemplate] {
        var folders = [builtInFolder]
        if !AppEnvironment.isScripted { folders.append(ownFolder) }
        return folders.flatMap { load(from: $0) }
    }

    static func revealOwnFolder() {
        try? FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ownFolder)
    }

    private static func load(from folder: URL) -> [MarkdownTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { file in
                (try? String(contentsOf: file, encoding: .utf8)).map { MarkdownTemplate(fileName: file.lastPathComponent, text: $0) }
            }
    }
}
