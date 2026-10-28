import Foundation

/// How a text file is written on disk — encoding, byte-order mark and line endings — so an
/// edited file is saved back the way it was (a GBK file with CRLF stays GBK with CRLF).
public struct TextFileFormat: Sendable, Equatable {
    public var encoding: DetectedEncoding
    /// "\n", "\r\n" or "\r"; the text is edited with "\n" and converted back on save.
    public var lineEnding: String

    public init(encoding: DetectedEncoding, lineEnding: String) {
        self.encoding = encoding
        self.lineEnding = lineEnding
    }

    public static let utf8LF = TextFileFormat(encoding: .utf8, lineEnding: "\n")

    /// Reads a file: its text with "\n" line endings, and the format to write it back in.
    public static func read(_ url: URL) throws -> (String, TextFileFormat) {
        let data = try Data(contentsOf: url)
        let (raw, enc) = TextEncodingDetector.decode(data)
        let ending = dominantLineEnding(raw)
        let text = ending == "\n" ? raw : raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (text, TextFileFormat(encoding: enc, lineEnding: ending))
    }

    /// The line ending most lines use (mixed files are normalised to it).
    static func dominantLineEnding(_ s: String) -> String {
        var crlf = 0, lf = 0, cr = 0
        var prevCR = false
        for u in s.utf8 {
            if u == 13 { if prevCR { cr += 1 }; prevCR = true; continue }
            if u == 10 { if prevCR { crlf += 1 } else { lf += 1 } }
            else if prevCR { cr += 1 }
            prevCR = false
        }
        if prevCR { cr += 1 }
        if crlf > lf && crlf >= cr { return "\r\n" }
        if cr > lf && cr > crlf { return "\r" }
        return "\n"
    }

    /// Bytes for `text` in this format. Falls back to UTF-8 (keptEncoding false) when the
    /// original encoding cannot represent some character.
    public func encode(_ text: String) -> (data: Data, keptEncoding: Bool) {
        let body = lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding)
        if let d = body.data(using: encoding.encoding, allowLossyConversion: false) {
            // String's UTF-16/32 encoders add their own BOM; keep exactly what the file had.
            let plain = stripAddedBOM(d)
            return (bom + plain, true)
        }
        return ((encoding.bomLength > 0 ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(body.utf8), false)
    }

    private var bom: Data {
        guard encoding.bomLength > 0 else { return Data() }
        switch encoding.encoding {
        case .utf8: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: return Data([0xFF, 0xFE])
        case .utf16BigEndian: return Data([0xFE, 0xFF])
        case .utf32LittleEndian: return Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian: return Data([0x00, 0x00, 0xFE, 0xFF])
        default: return Data()
        }
    }

    private func stripAddedBOM(_ d: Data) -> Data {
        let marks: [Data]
        switch encoding.unitWidth {
        case 4: marks = [Data([0xFF, 0xFE, 0x00, 0x00]), Data([0x00, 0x00, 0xFE, 0xFF])]
        case 2: marks = [Data([0xFF, 0xFE]), Data([0xFE, 0xFF])]
        default: marks = [Data([0xEF, 0xBB, 0xBF])]
        }
        for m in marks where d.starts(with: m) { return Data(d.dropFirst(m.count)) }
        return d
    }

    /// Writes atomically (a failure never leaves a half-written file).
    /// Returns false when the text had to be saved as UTF-8 instead of the original encoding.
    @discardableResult
    public func write(_ text: String, to url: URL) throws -> Bool {
        let (data, kept) = encode(text)
        try data.write(to: url, options: .atomic)
        return kept
    }
}
