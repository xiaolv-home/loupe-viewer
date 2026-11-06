import Foundation
import Testing

@testable import LoupeApp

@Suite("侧栏的文件操作")
struct FileOperationsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("内容".utf8).write(to: url)
        return url
    }

    @Test("重命名不会覆盖已有文件")
    func renameKeepsExisting() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        let a = try file("a.md", in: d)
        _ = try file("b.md", in: d)
        #expect(throws: FileOperations.Failure.self) { try FileOperations.rename(a, to: "b.md") }
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test("只改大小写也能重命名")
    func renameCase() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        let a = try file("a.md", in: d)
        let renamed = try FileOperations.rename(a, to: "A.md")
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["A.md"])
        #expect(renamed.lastPathComponent == "A.md")
    }

    @Test("名字不能带路径", arguments: ["", "  ", "..", "a/b", "a:b"])
    func badNames(name: String) throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        let a = try file("a.md", in: d)
        #expect(throws: FileOperations.Failure.self) { try FileOperations.rename(a, to: name) }
    }

    @Test("副本依次编号，保留扩展名")
    func duplicates() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        let a = try file("报表.xlsx", in: d)
        #expect(try FileOperations.duplicate(a).lastPathComponent == "报表 副本.xlsx")
        #expect(try FileOperations.duplicate(a).lastPathComponent == "报表 副本 2.xlsx")
    }

    @Test("新建文件夹遇到重名自动编号")
    func folders() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        #expect(try FileOperations.createFolder(named: "资料", in: d).lastPathComponent == "资料")
        #expect(try FileOperations.createFolder(named: "资料", in: d).lastPathComponent == "资料 2")
    }
}
