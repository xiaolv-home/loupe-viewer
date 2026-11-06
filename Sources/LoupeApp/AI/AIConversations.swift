import Foundation
import LoupeCore

/// A saved conversation: what the model saw (history) and what the panel showed (items).
struct AIConversation: Codable, Identifiable {
    var id = UUID()
    var title: String
    var created = Date()
    var updated = Date()
    /// Where it was talking ("本地 · qwen…" / "云端 · DeepSeek · …").
    var model: String
    /// The file that was open when the conversation started.
    var file: String?
    var history: [AIMessage]
    var items: [AIItem]
}

/// Every conversation, saved on this Mac in ~/Library/Application Support/Loupe/Conversations
/// (one file each, plus a small index for the list).
@MainActor
final class AIConversations: ObservableObject {
    static let shared = AIConversations()

    struct Summary: Codable, Identifiable, Equatable {
        var id: UUID
        var title: String
        var updated: Date
        var model: String
        var file: String?
        var preview: String
    }

    @Published private(set) var list: [Summary] = []

    static let root: URL = {
        // The debug harness keeps its conversations out of the user's history.
        if AppEnvironment.isScripted {
            return FileManager.default.temporaryDirectory.appendingPathComponent("loupe-harness-conversations", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Loupe/Conversations", isDirectory: true)
    }()

    private var indexURL: URL { Self.root.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { Self.root.appendingPathComponent(id.uuidString + ".json") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL), let l = try? JSONDecoder.loupe.decode([Summary].self, from: d) {
            list = l.sorted { $0.updated > $1.updated }
        } else {
            rebuildIndex()
        }
    }

    func save(_ c: AIConversation) {
        guard let data = try? JSONEncoder.loupe.encode(c) else { return }
        try? data.write(to: url(c.id), options: .atomic)
        let preview = c.items.reversed().lazy.compactMap { item -> String? in
            if case .assistant(let t) = item.kind { return t }
            return nil
        }.first.map { MarkdownParser.plain($0).replacingOccurrences(of: "\n", with: " ") } ?? ""
        let s = Summary(id: c.id, title: c.title, updated: c.updated, model: c.model, file: c.file, preview: String(preview.prefix(80)))
        list.removeAll { $0.id == c.id }
        list.insert(s, at: 0)
        writeIndex()
    }

    func load(_ id: UUID) -> AIConversation? {
        guard let d = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder.loupe.decode(AIConversation.self, from: d)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        list.removeAll { $0.id == id }
        writeIndex()
    }

    func deleteAll() {
        for s in list { try? FileManager.default.removeItem(at: url(s.id)) }
        list = []
        writeIndex()
    }

    private func writeIndex() {
        if let d = try? JSONEncoder.loupe.encode(list) { try? d.write(to: indexURL, options: .atomic) }
    }

    /// Recovers the list from the conversation files (first run, or a lost index).
    private func rebuildIndex() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        list = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }.compactMap { u in
            guard let d = try? Data(contentsOf: u), let c = try? JSONDecoder.loupe.decode(AIConversation.self, from: d) else { return nil }
            return Summary(id: c.id, title: c.title, updated: c.updated, model: c.model, file: c.file, preview: "")
        }.sorted { $0.updated > $1.updated }
        writeIndex()
    }

    /// The list grouped the way people think about time: 今天 / 昨天 / 7 天内 / 30 天内 / 更早.
    func grouped(matching query: String) -> [(String, [Summary])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = q.isEmpty ? list : list.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.preview.localizedCaseInsensitiveContains(q) || ($0.file?.localizedCaseInsensitiveContains(q) ?? false)
        }
        let cal = Calendar.current
        let now = Date()
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "今天" }
            if cal.isDateInYesterday(d) { return "昨天" }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
            if days < 7 { return "7 天内" }
            if days < 30 { return "30 天内" }
            return "更早"
        }
        var out: [(String, [Summary])] = []
        for s in items {
            let b = bucket(s.updated)
            if out.last?.0 == b { out[out.count - 1].1.append(s) } else { out.append((b, [s])) }
        }
        return out
    }
}

extension JSONEncoder {
    static var loupe: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var loupe: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
