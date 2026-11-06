import Foundation
import Testing
import LoupeCore
@testable import LoupeApp

/// The AI's tools work through a small protocol, so they run here with no window at all.
@MainActor
@Suite("AI 工具不依赖具体窗口")
struct AIWorkspaceTests {
    private final class FakeDocument: AIDocument {
        var file: FileContext?
        var renderer: Renderer?
    }

    private final class FakeWorkspace: AIWorkspace {
        var aiDocument: AIDocument?
        var aiBrowsingFolder: URL?
        var opened: [URL] = []
        func aiOpen(_ url: URL) { opened.append(url) }
    }

    private func toolbox(_ workspace: FakeWorkspace?) -> AIToolbox {
        AIToolbox(document: workspace?.aiDocument, workspace: workspace, skills: [], allowCommands: false) { _ in false }
    }

    @Test("打开文件交给所在窗口")
    func opensThroughWorkspace() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: file)
        let workspace = FakeWorkspace()
        workspace.aiBrowsingFolder = folder
        let out = await toolbox(workspace).run(
            AIToolCall(id: "1", name: "open_file", arguments: "{\"path\":\"a.txt\"}"), AIJSON.object(["path": .string("a.txt")]))
        #expect(!out.isError)
        #expect(workspace.opened.map(\.lastPathComponent) == ["a.txt"])
    }

    @Test("没有窗口时报错，不会崩")
    func noWindow() async throws {
        let folder = FileManager.default.temporaryDirectory
        let name = UUID().uuidString + ".txt"
        let file = folder.appendingPathComponent(name)
        try Data("hi".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let out = await toolbox(nil).run(AIToolCall(id: "1", name: "open_file", arguments: "{}"), AIJSON.object(["path": .string(file.path)]))
        #expect(out.isError)
    }
}
