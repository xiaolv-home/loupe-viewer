import Foundation
import LoupeCore

/// The skills the AI can use: Loupe's own (shipped in the app) and ones installed from GitHub
/// into ~/Library/Application Support/Loupe/Skills.
@MainActor
final class AISkills: ObservableObject {
    static let shared = AISkills()

    static let builtInRoot: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("skills"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills")
    }()

    static let installedRoot: URL = {
        // The debug harness installs into a scratch folder, never the user's library.
        if AppEnvironment.isScripted {
            return FileManager.default.temporaryDirectory.appendingPathComponent("loupe-harness-skills", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Loupe/Skills", isDirectory: true).standardizedFileURL
    }()

    @Published private(set) var all: [Skill] = []
    /// Catalog entries being installed (by URL) and their progress text.
    @Published var installing: [String: String] = [:]

    private init() { reload() }

    func reload() {
        all = SkillLibrary.scan(builtIn: [Self.builtInRoot], installed: Self.installedRoot)
    }

    /// How a skill is remembered as switched off (built-in and installed ones may share a folder name).
    static func key(_ s: Skill) -> String { (s.builtIn ? "builtin/" : "") + s.folder.lastPathComponent }

    var enabled: [Skill] {
        let off = AIConfig.shared.disabledSkills
        return all.filter { !off.contains(Self.key($0)) }
    }

    func isEnabled(_ s: Skill) -> Bool { !AIConfig.shared.disabledSkills.contains(Self.key(s)) }

    func setEnabled(_ s: Skill, _ on: Bool) {
        if on { AIConfig.shared.disabledSkills.remove(Self.key(s)) } else { AIConfig.shared.disabledSkills.insert(Self.key(s)) }
        objectWillChange.send()
    }

    func find(_ name: String) -> Skill? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return enabled.first { $0.name.lowercased() == n || $0.folder.lastPathComponent.lowercased() == n }
            ?? enabled.first { $0.name.lowercased().contains(n) || n.contains($0.name.lowercased()) }
    }

    /// Installs every skill found at a GitHub link.
    @discardableResult
    func install(_ link: String) async throws -> [Skill] {
        guard let src = SkillInstaller.parse(link) else { throw AIError("看不懂这个链接，请贴 GitHub 仓库或文件夹的地址") }
        installing[link] = "下载中…"
        defer { installing[link] = nil }
        let skills = try await SkillInstaller.install(src, into: Self.installedRoot) { p in
            await MainActor.run {
                switch p {
                case .downloading: AISkills.shared.installing[link] = "下载中…"
                case .unpacking: AISkills.shared.installing[link] = "解压中…"
                case .installing: AISkills.shared.installing[link] = "安装中…"
                }
            }
        }
        reload()
        return skills
    }

    func remove(_ s: Skill) {
        guard !s.builtIn else { return }
        try? FileManager.default.trashItem(at: s.folder, resultingItemURL: nil)
        reload()
    }

    /// Installed skills that came from a catalog entry's repository.
    func installed(from entry: SkillCatalog.Entry) -> [Skill] {
        guard let src = SkillInstaller.parse(entry.url) else { return [] }
        let prefix = "https://github.com/\(src.owner)/\(src.repo)".lowercased()
        return all.filter { !$0.builtIn && ($0.source?.lowercased().hasPrefix(prefix) ?? false) }
    }
}
