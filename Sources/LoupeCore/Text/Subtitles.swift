import Foundation

public struct SubtitleCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
}

/// Parses SRT, WebVTT and ASS/SSA into cues sorted by start time.
public enum SubtitleParser {
    public static let extensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    public static func parse(url: URL) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let (text, _) = TextEncodingDetector.decode(data)
        return parse(text, ext: url.pathExtension.lowercased())
    }

    public static func parse(_ text: String, ext: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let cues: [SubtitleCue]
        switch ext {
        case "ass", "ssa": cues = parseASS(normalized)
        default: cues = parseTimed(normalized)
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// SRT and VTT share the "start --> end" block structure.
    static func parseTimed(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = parseTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let e = parseTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: s, end: e, text: stripTags(body)))
        }
        return cues
    }

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var format: [String] = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            let body = line.dropFirst(9)
            // The last field (Text) may itself contain commas.
            let fields = body.split(separator: ",", maxSplits: max(format.count - 1, 0), omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == format.count,
                  let si = format.firstIndex(of: "start"), let ei = format.firstIndex(of: "end"),
                  let xi = format.firstIndex(of: "text"),
                  let s = parseTime(fields[si]), let e = parseTime(fields[ei]) else { continue }
            var t = fields[xi]
            t = t.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
            t = t.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: t)) }
        }
        return cues
    }

    /// Accepts "hh:mm:ss,mmm", "hh:mm:ss.mmm", "mm:ss.mmm", "h:mm:ss.cc".
    public static func parseTime(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p) else { return nil }
            if i < parts.count - 1 { total = (total + v) * 60 } else { total += v }
        }
        return total
    }

    static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Binary search for the cue visible at `time`.
    public static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        // Overlapping cues: walk back a little to find one that still covers `time`.
        var i = found
        while i >= 0 && i > found - 8 {
            if cues[i].start <= time && time < cues[i].end { return cues[i] }
            i -= 1
        }
        return nil
    }
}
