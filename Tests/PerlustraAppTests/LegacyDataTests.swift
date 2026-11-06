import Foundation
import Testing

@testable import PerlustraApp

@Suite struct LegacyDataTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-tests/legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func settingsKeepTheirMeaningUnderTheNewName() {
        let old: [String: Any] = [
            "NSWindow Frame LoupeMainWindow": "10 10 800 600",
            "recentFiles": ["/L/Loupe/Drafts/a.md", "/Users/me/Documents/b.xlsx"],
            "lastDraft": "/L/Loupe/Drafts/a.md",
            "showSidebar": true,
        ]
        let new = LegacyData.converted(old, from: "/L/Loupe", to: "/L/Perlustra")
        #expect(new["NSWindow Frame PerlustraMainWindow"] as? String == "10 10 800 600")
        #expect(new["NSWindow Frame LoupeMainWindow"] == nil)
        #expect(new["recentFiles"] as? [String] == ["/L/Perlustra/Drafts/a.md", "/Users/me/Documents/b.xlsx"])
        #expect(new["lastDraft"] as? String == "/L/Perlustra/Drafts/a.md")
        #expect(new["showSidebar"] as? Bool == true)
    }

    @Test func foldersMoveWithoutOverwritingAnything() throws {
        let root = try temporaryFolder()
        let old = root.appendingPathComponent("Loupe"), new = root.appendingPathComponent("Perlustra")
        let files = FileManager.default
        try files.createDirectory(at: old.appendingPathComponent("Drafts"), withIntermediateDirectories: true)
        try files.createDirectory(at: new.appendingPathComponent("Drafts"), withIntermediateDirectories: true)
        try Data("old key".utf8).write(to: old.appendingPathComponent("ai-keys.json"))
        try Data("old draft".utf8).write(to: old.appendingPathComponent("Drafts/a.md"))
        try Data("kept".utf8).write(to: old.appendingPathComponent("Drafts/both.md"))
        try Data("newer".utf8).write(to: new.appendingPathComponent("Drafts/both.md"))

        #expect(LegacyData.moveContents(of: old, into: new))
        #expect(try String(contentsOf: new.appendingPathComponent("ai-keys.json"), encoding: .utf8) == "old key")
        #expect(try String(contentsOf: new.appendingPathComponent("Drafts/a.md"), encoding: .utf8) == "old draft")
        #expect(try String(contentsOf: new.appendingPathComponent("Drafts/both.md"), encoding: .utf8) == "newer")
        // What could not move stays where it was rather than being lost.
        #expect(files.fileExists(atPath: old.appendingPathComponent("Drafts/both.md").path))
    }

    @Test func nothingToMoveIsNotAFailure() throws {
        let root = try temporaryFolder()
        #expect(LegacyData.moveContents(of: root.appendingPathComponent("never-there"), into: root.appendingPathComponent("new")))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
    }
}
