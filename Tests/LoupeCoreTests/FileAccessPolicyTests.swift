import Foundation
import Testing
@testable import LoupeCore

@Suite("路径与回环地址")
struct FileAccessPolicyTests {
    @Test("目录边界带斜杠，相邻且同前缀的目录不算在内")
    func boundary() {
        #expect(FileAccessPolicy.contains("/tmp/web/a.js", root: "/tmp/web"))
        #expect(FileAccessPolicy.contains("/tmp/web", root: "/tmp/web"))
        #expect(!FileAccessPolicy.contains("/tmp/web-secret/a.js", root: "/tmp/web"))
        #expect(!FileAccessPolicy.contains("/tmp/web2", root: "/tmp/web"))
    }

    @Test("打包资源不能用 .. 跳出目录")
    func bundledEscape() throws {
        let root = TestTemp.dir("webroot")
        let vendor = root.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let js = vendor.appendingPathComponent("a.js")
        FileManager.default.createFile(atPath: js.path, contents: Data("ok".utf8))
        let found = FileAccessPolicy.bundledFile(root: root, relativePath: "/vendor/a.js")
        #expect(found?.standardizedFileURL.path == js.standardizedFileURL.path)
        let siblingName = root.lastPathComponent + "-secret"
        let escaped = FileAccessPolicy.bundledFile(root: root, relativePath: "../" + siblingName + "/x")
        #expect(escaped == nil)
    }

    @Test("文件夹内的符号链接解析后若离开根目录则拒绝")
    func symlinkEscape() throws {
        let root = TestTemp.dir("site")
        let outside = TestTemp.dir("outside")
        let secret = outside.appendingPathComponent("id_rsa")
        FileManager.default.createFile(atPath: secret.path, contents: Data("secret".utf8))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(FileAccessPolicy.fileInsideRoot(link, root: root) == nil)
        let page = root.appendingPathComponent("index.html")
        FileManager.default.createFile(atPath: page.path, contents: Data("<p>".utf8))
        let allowed = FileAccessPolicy.fileInsideRoot(page, root: root)
        #expect(allowed?.standardizedFileURL.path == page.standardizedFileURL.path)
    }

    @Test("读取拒绝家目录里任意隐藏段和 ~/Library，技能目录除外")
    func readRules() throws {
        let home = TestTemp.dir("home")
        let project = home.appendingPathComponent("Projects/app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let env = project.appendingPathComponent(".env")
        #expect(FileAccessPolicy.readDenial(env, home: home, skillRoots: []) != nil)
        let nestedSSH = project.appendingPathComponent(".ssh/id_rsa")
        #expect(FileAccessPolicy.readDenial(nestedSSH, home: home, skillRoots: []) != nil)
        let topSSH = home.appendingPathComponent(".ssh/id_rsa")
        #expect(FileAccessPolicy.readDenial(topSSH, home: home, skillRoots: []) != nil)
        let mail = home.appendingPathComponent("Library/Mail/box")
        #expect(FileAccessPolicy.readDenial(mail, home: home, skillRoots: []) != nil)
        let note = home.appendingPathComponent("Documents/note.txt")
        #expect(FileAccessPolicy.readDenial(note, home: home, skillRoots: []) == nil)
        let skills = home.appendingPathComponent("Library/Application Support/Loupe/Skills/demo")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let skillFile = skills.appendingPathComponent("SKILL.md")
        #expect(FileAccessPolicy.readDenial(skillFile, home: home, skillRoots: [skills.deletingLastPathComponent()]) == nil)
        #expect(FileAccessPolicy.readDenial(URL(fileURLWithPath: "/etc/passwd"), home: home, skillRoots: []) != nil)
    }

    @Test("符号链接指向隐藏目录时按解析后的路径拒绝读取")
    func readFollowsSymlink() throws {
        let home = TestTemp.dir("home-link")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("id_rsa")
        FileManager.default.createFile(atPath: key.path, contents: Data("k".utf8))
        let project = home.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let link = project.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        #expect(FileAccessPolicy.readDenial(link, home: home, skillRoots: []) != nil)
    }

    @Test("写入只留在个人文件夹，拒绝隐藏段、Library，允许 /tmp")
    func writeRules() throws {
        let home = TestTemp.dir("home-write")
        let doc = home.appendingPathComponent("Documents/a.txt")
        #expect(FileAccessPolicy.writeDenial(doc, home: home) == nil)
        let hidden = home.appendingPathComponent("Projects/.secret/a")
        #expect(FileAccessPolicy.writeDenial(hidden, home: home) != nil)
        let library = home.appendingPathComponent("Library/Logs/a")
        #expect(FileAccessPolicy.writeDenial(library, home: home) != nil)
        #expect(FileAccessPolicy.writeDenial(URL(fileURLWithPath: "/tmp/loupe-write-test.txt"), home: home) == nil)
        #expect(FileAccessPolicy.writeDenial(URL(fileURLWithPath: "/etc/passwd"), home: home) != nil)
    }

    @Test("回环地址只认 localhost 和 127.0.0.0/8")
    func loopback() {
        #expect(FileAccessPolicy.isLoopback(host: "localhost"))
        #expect(FileAccessPolicy.isLoopback(host: "127.0.0.1"))
        #expect(FileAccessPolicy.isLoopback(host: "127.1.2.3"))
        #expect(FileAccessPolicy.isLoopback(host: "::1"))
        #expect(FileAccessPolicy.isLoopback(host: "[::1]"))
        #expect(!FileAccessPolicy.isLoopback(host: "192.168.1.2"))
        #expect(!FileAccessPolicy.isLoopback(host: "10.0.0.1"))
        #expect(!FileAccessPolicy.isLoopback(host: "example.com"))
        #expect(!FileAccessPolicy.isLoopback(host: nil))
        let local = URL(string: "http://127.0.0.1:1234/v1")!
        #expect(FileAccessPolicy.isLoopback(url: local))
        let lan = URL(string: "http://192.168.1.5:11434/v1")!
        #expect(!FileAccessPolicy.isLoopback(url: lan))
        let file = URL(string: "file:///tmp/x")!
        #expect(!FileAccessPolicy.isLoopback(url: file))
    }
}
