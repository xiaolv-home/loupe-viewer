import Foundation

/// Markdown split into blocks and inline runs — the one parser behind the AI's Word, PDF and web
/// output and the answers shown in the AI panel.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph([String])
    case list(ordered: Bool, items: [String])
    case table(header: [String], rows: [[String]])
    case quote([String])
    case code(String)
    case rule
}

public struct MarkdownRun: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var strike = false
    public var link: String?
    public init(_ text: String) { self.text = text }
}

public enum MarkdownParser {
    public static func blocks(_ md: String) -> [MarkdownBlock] {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var list: (ordered: Bool, items: [String])?
        var i = 0
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para)); para = [] } }
        func flushList() { if let l = list { out.append(.list(ordered: l.ordered, items: l.items)); list = nil } }
        func flushAll() { flushPara(); flushList() }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { flushAll(); continue }
            if line.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                i += 1
                out.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let h = heading(line) { flushAll(); out.append(.heading(level: h.level, text: h.text)); continue }
            if line.count >= 3, line.allSatisfy({ "-*_ ".contains($0) }), Set(line.filter { $0 != " " }).count == 1 {
                flushAll(); out.append(.rule); continue
            }
            if line.hasPrefix("|"), i < lines.count, isTableRule(lines[i]) {
                flushAll()
                let header = cells(line)
                i += 1
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var r = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(r)
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if line.hasPrefix(">") {
                flushAll()
                var q = [String(line.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(q))
                continue
            }
            if let item = listItem(line) {
                flushPara()
                if list == nil || list!.ordered != item.ordered { flushList(); list = (item.ordered, []) }
                list!.items.append(item.text)
                continue
            }
            if list != nil, raw.hasPrefix("  ") || raw.hasPrefix("\t") {
                list!.items[list!.items.count - 1] += " " + line
                continue
            }
            flushList()
            para.append(line)
        }
        flushAll()
        return out
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let n = line.prefix { $0 == "#" }.count
        guard (1...6).contains(n), line.dropFirst(n).first == " " else { return nil }
        let t = line.dropFirst(n).trimmingCharacters(in: .whitespaces)
        return (n, t.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
    }

    static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for m in ["- ", "* ", "+ ", "• "] where line.hasPrefix(m) {
            var t = String(line.dropFirst(2))
            if t.hasPrefix("[ ] ") { t = "☐ " + t.dropFirst(4) } else if t.lowercased().hasPrefix("[x] ") { t = "☑ " + t.dropFirst(4) }
            return (false, t)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (true, rest.dropFirst(2).trimmingCharacters(in: .whitespaces)) }
        if rest.hasPrefix("、") { return (true, rest.dropFirst(1).trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func isTableRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Emphasis, code, strike-through and links within one line of text.
    public static func runs(_ s: String) -> [MarkdownRun] {
        var out: [MarkdownRun] = []
        var cur = MarkdownRun("")
        var bold = false, italic = false, strike = false
        let chars = Array(s)
        var i = 0
        func flush() { if !cur.text.isEmpty { out.append(cur) }; cur = MarkdownRun(""); cur.bold = bold; cur.italic = italic; cur.strike = strike }
        func closes(_ marker: String, from j: Int) -> Bool {
            String(chars[j...]).range(of: marker) != nil
        }
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                flush()
                var r = MarkdownRun(String(chars[(i + 1)..<end])); r.code = true; r.bold = bold; r.italic = italic
                out.append(r)
                i = end + 1
                continue
            }
            if (c == "*" || c == "_"), next == c, bold || closes(String([c, c]), from: i + 2) {
                flush(); bold.toggle(); cur.bold = bold; i += 2; continue
            }
            if c == "~", next == "~", strike || closes("~~", from: i + 2) {
                flush(); strike.toggle(); cur.strike = strike; i += 2; continue
            }
            if c == "*", italic || (next.map { !$0.isWhitespace } ?? false) && closes("*", from: i + 1) {
                flush(); italic.toggle(); cur.italic = italic; i += 1; continue
            }
            if c == "[", let close = chars[i...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(",
               let paren = chars[(close + 1)...].firstIndex(of: ")") {
                flush()
                var r = MarkdownRun(String(chars[(i + 1)..<close])); r.link = String(chars[(close + 2)..<paren]); r.bold = bold; r.italic = italic
                out.append(r)
                i = paren + 1
                continue
            }
            cur.text.append(c)
            i += 1
        }
        flush()
        return out
    }

    /// The text without Markdown markers.
    public static func plain(_ s: String) -> String { runs(s).map(\.text).joined() }
}
