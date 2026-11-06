import Foundation

/// A Markdown document to start from. Places to fill in are written 〔like this〕, a pair of brackets
/// seldom found in ordinary text, so the writer can find them and step through them with Tab.
public struct MarkdownTemplate: Identifiable, Hashable, Sendable {
    public static let ownGroup = "我的模版"

    public let id: String
    public let title: String
    public let group: String
    public let summary: String
    public let body: String

    /// Reads a template file. Optional header lines give its title, group and summary; without
    /// them, as in a file someone just dropped in their own templates folder, the file name is the title.
    public init(fileName: String, text: String) {
        id = fileName
        var header: [String: String] = [:]
        var rest = text.replacingOccurrences(of: "\r\n", with: "\n")
        if rest.hasPrefix("---\n"), let end = rest.range(of: "\n---\n") {
            for line in rest[rest.index(rest.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                header[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            rest = String(rest[end.upperBound...])
        }
        body = rest.trimmingCharacters(in: .newlines) + "\n"
        title = header["title"] ?? (fileName as NSString).deletingPathExtension
        group = header["group"] ?? Self.ownGroup
        summary = header["summary"] ?? ""
    }

    /// The text of a new document made from this template, on a given day.
    public func document(on date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let today = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return body.replacingOccurrences(of: "〔今天〕", with: today)
    }

    /// The places still to fill in, in order. A year in such brackets, as in official document
    /// numbers, is not one. The writer finds them the same way; see `blankPattern` in writer.js.
    public static func blanks(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "〔[^〔〕\\n]{1,60}〕") else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let blank = String(text[range])
            return blank.dropFirst().dropLast().allSatisfy(\.isNumber) ? nil : blank
        }
    }

    /// Those whose title, summary or text holds every word typed.
    public static func matching(_ templates: [MarkdownTemplate], query: String) -> [MarkdownTemplate] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return templates }
        return templates.filter { template in
            let text = (template.title + template.summary + template.group + template.body).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}
