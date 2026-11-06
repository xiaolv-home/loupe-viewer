import Foundation

/// Streaming RFC 4180 parser operating on bytes. Works for UTF-8 and GB18030 because
/// delimiter, quote and newline bytes never occur inside their multi-byte sequences.
public struct CSVParser {
    public let delimiter: UInt8
    public let encoding: String.Encoding
    private var field: [UInt8] = []
    private var row: [String] = []
    private var inQuotes = false
    private var quoteSeenInQuotes = false
    private var lastWasCR = false

    public init(delimiter: UInt8, encoding: String.Encoding = .utf8) {
        self.delimiter = delimiter
        self.encoding = encoding
    }

    private func decodeField(_ bytes: [UInt8]) -> String {
        if encoding == .utf8 { return String(decoding: bytes, as: UTF8.self) }
        return String(bytes: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
    }

    private mutating func endField() {
        row.append(decodeField(field))
        field.removeAll(keepingCapacity: true)
    }

    /// Feeds a chunk; returns the rows completed within it.
    public mutating func feed(_ chunk: Data) -> [[String]] {
        var out: [[String]] = []
        let q = UInt8(ascii: "\"")
        chunk.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for c in p {
                if inQuotes {
                    if quoteSeenInQuotes {
                        quoteSeenInQuotes = false
                        if c == q { field.append(q); continue }
                        inQuotes = false
                        // fall through to unquoted handling of c
                    } else if c == q {
                        quoteSeenInQuotes = true
                        continue
                    } else {
                        field.append(c)
                        continue
                    }
                }
                if c == delimiter {
                    endField(); lastWasCR = false
                } else if c == 0x0A {
                    if lastWasCR { lastWasCR = false; continue }
                    endField(); out.append(row); row.removeAll(keepingCapacity: true)
                } else if c == 0x0D {
                    endField(); out.append(row); row.removeAll(keepingCapacity: true)
                    lastWasCR = true
                } else if c == q && field.isEmpty {
                    inQuotes = true; lastWasCR = false
                } else {
                    field.append(c); lastWasCR = false
                }
            }
        }
        return out
    }

    /// Flushes the final row (file without trailing newline).
    public mutating func finish() -> [String]? {
        if quoteSeenInQuotes { inQuotes = false; quoteSeenInQuotes = false }
        if field.isEmpty && row.isEmpty { return nil }
        endField()
        let r = row
        row.removeAll()
        return r
    }

    /// Convenience for small inputs and tests.
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var p = CSVParser(delimiter: delimiter.asciiValue ?? 44)
        var rows = p.feed(Data(text.utf8))
        if let last = p.finish() { rows.append(last) }
        return rows
    }
}
