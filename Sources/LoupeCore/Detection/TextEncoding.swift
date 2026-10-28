import Foundation

public struct DetectedEncoding: Sendable, Equatable {
    public var encoding: String.Encoding
    public var name: String
    /// Bytes of BOM to skip.
    public var bomLength: Int
    /// Code unit width for line scanning (1 for byte-oriented, 2 for UTF-16, 4 for UTF-32).
    public var unitWidth: Int
    public var bigEndian: Bool

    public init(_ encoding: String.Encoding, _ name: String, bom: Int = 0, unit: Int = 1, bigEndian: Bool = false) {
        self.encoding = encoding
        self.name = name
        self.bomLength = bom
        self.unitWidth = unit
        self.bigEndian = bigEndian
    }

    public static let utf8 = DetectedEncoding(.utf8, "UTF-8")
    public static let gb18030 = DetectedEncoding(
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        "GB18030")
}

public enum TextEncodingDetector {
    public static let gb18030 = DetectedEncoding.gb18030.encoding
    public static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
    public static let shiftJIS = String.Encoding.shiftJIS
    public static let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))

    /// Detects the encoding using BOMs, UTF-16 patterns, UTF-8 validity, then CJK legacy encodings.
    public static func detect(_ data: Data) -> DetectedEncoding {
        let sample = data.prefix(256 * 1024)
        let b = [UInt8](sample.prefix(4))
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return DetectedEncoding(.utf8, "UTF-8 (BOM)", bom: 3) }
        if b.count >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0 && b[3] == 0 { return DetectedEncoding(.utf32LittleEndian, "UTF-32 LE", bom: 4, unit: 4) }
        if b.count >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0xFE && b[3] == 0xFF { return DetectedEncoding(.utf32BigEndian, "UTF-32 BE", bom: 4, unit: 4, bigEndian: true) }
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE { return DetectedEncoding(.utf16LittleEndian, "UTF-16 LE", bom: 2, unit: 2) }
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return DetectedEncoding(.utf16BigEndian, "UTF-16 BE", bom: 2, unit: 2, bigEndian: true) }

        if let u16 = utf16WithoutBOM(sample) { return u16 }
        if isValidUTF8(sample, allowTruncatedTail: data.count > sample.count || true) {
            return .utf8
        }
        // Legacy CJK. Score each candidate by the share of "plausible" characters.
        var best: (DetectedEncoding, Double)? = nil
        let candidates: [DetectedEncoding] = [
            DetectedEncoding(gb18030, "GB18030"),
            DetectedEncoding(big5, "Big5"),
            DetectedEncoding(shiftJIS, "Shift_JIS"),
            DetectedEncoding(eucKR, "EUC-KR")
        ]
        let trimmed = trimToLastNewline(sample)
        for c in candidates {
            guard let s = String(data: trimmed, encoding: c.encoding) else { continue }
            let score = plausibility(s, for: c.name)
            if best == nil || score > best!.1 { best = (c, score) }
        }
        if let (enc, score) = best, score > 0.55 {
            // Name GBK when only GBK-range characters appear (common case for "GBK" files).
            if enc.name == "GB18030" { return DetectedEncoding(enc.encoding, "GBK / GB18030") }
            return enc
        }
        if String(data: trimmed, encoding: .windowsCP1252) != nil {
            return DetectedEncoding(.windowsCP1252, "Windows-1252")
        }
        return DetectedEncoding(.isoLatin1, "ISO-8859-1")
    }

    /// Decodes data with the detected encoding, never failing (lossy as a last resort).
    public static func decode(_ data: Data, as enc: DetectedEncoding) -> String {
        let body = enc.bomLength > 0 ? data.dropFirst(enc.bomLength) : data[...]
        if let s = String(data: Data(body), encoding: enc.encoding) { return s }
        if enc.encoding == .utf8 {
            return String(decoding: body, as: UTF8.self)
        }
        // Retry after trimming a partial trailing character.
        if let s = String(data: trimToLastNewline(Data(body)), encoding: enc.encoding) { return s }
        return String(decoding: body, as: UTF8.self)
    }

    public static func decode(_ data: Data) -> (String, DetectedEncoding) {
        let enc = detect(data)
        return (decode(data, as: enc), enc)
    }

    // MARK: helpers

    static func utf16WithoutBOM(_ d: Data) -> DetectedEncoding? {
        let n = min(d.count, 4096) & ~1
        guard n >= 16 else { return nil }
        var evenZero = 0, oddZero = 0
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in stride(from: 0, to: n, by: 2) {
                if p[i] == 0 { evenZero += 1 }
                if p[i + 1] == 0 { oddZero += 1 }
            }
        }
        let pairs = n / 2
        if Double(oddZero) / Double(pairs) > 0.3 && Double(evenZero) / Double(pairs) < 0.05 {
            return DetectedEncoding(.utf16LittleEndian, "UTF-16 LE", unit: 2)
        }
        if Double(evenZero) / Double(pairs) > 0.3 && Double(oddZero) / Double(pairs) < 0.05 {
            return DetectedEncoding(.utf16BigEndian, "UTF-16 BE", unit: 2, bigEndian: true)
        }
        return nil
    }

    /// Strict UTF-8 validation. A multi-byte sequence cut off at the very end is tolerated.
    public static func isValidUTF8(_ d: Data, allowTruncatedTail: Bool = true) -> Bool {
        return d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            let n = p.count
            var i = 0
            while i < n {
                let c = p[i]
                if c < 0x80 { i += 1; continue }
                var need = 0
                if c & 0xE0 == 0xC0 { need = 1; if c < 0xC2 { return false } }
                else if c & 0xF0 == 0xE0 { need = 2 }
                else if c & 0xF8 == 0xF0 { need = 3; if c > 0xF4 { return false } }
                else { return false }
                if i + need >= n {
                    // Truncated at the end of the sample.
                    if !allowTruncatedTail { return false }
                    for j in (i + 1)..<n where p[j] & 0xC0 != 0x80 { return false }
                    return true
                }
                for j in 1...need where p[i + j] & 0xC0 != 0x80 { return false }
                i += need + 1
            }
            return true
        }
    }

    static func trimToLastNewline(_ d: Data) -> Data {
        guard d.count > 1024, let idx = d.lastIndex(of: 0x0A) else { return d }
        return d[d.startIndex...idx]
    }

    /// Share of non-ASCII scalars that are ideographs/kana/hangul or common CJK punctuation.
    static func plausibility(_ s: String, for name: String) -> Double {
        var nonASCII = 0, good = 0, han = 0, kana = 0, hangul = 0, privateUse = 0
        for u in s.unicodeScalars where u.value >= 0x80 {
            nonASCII += 1
            switch u.value {
            case 0x4E00...0x9FFF: good += 1; han += 1
            case 0x3400...0x4DBF: good += 1; han += 1
            case 0x3040...0x30FF: good += 1; kana += 1
            case 0xFF61...0xFF9F: break   // half-width katakana: typical of mis-decoded GBK
            case 0xAC00...0xD7AF: good += 1; hangul += 1
            case 0x3000...0x303F, 0xFF00...0xFFEF, 0x2010...0x206F, 0x00B7, 0x00D7, 0x2460...0x24FF, 0x2500...0x257F: good += 1
            case 0xE000...0xF8FF: privateUse += 1
            default: break
            }
            if nonASCII > 20000 { break }
        }
        guard nonASCII > 0 else { return 1 }
        var score = Double(good) / Double(nonASCII)
        score -= Double(privateUse) / Double(nonASCII)
        // Prefer the encoding whose script mix matches its region.
        switch name {
        case "Shift_JIS":
            if kana == 0 { score -= 0.2 }
            else if Double(kana) / Double(nonASCII) > 0.1 { score += 0.3 }  // real Japanese text is kana-rich
        case "EUC-KR": if hangul == 0 { score -= 0.3 }
        case "Big5": score -= 0.02  // tie-break toward GB18030 for zh-Hans users
        default: break
        }
        return score
    }
}

public enum TextSniffer {
    /// Heuristic: does this byte sample look like human-readable text in some encoding?
    public static func isLikelyText(_ d: Data) -> Bool {
        if d.isEmpty { return true }
        let sample = d.prefix(16 * 1024)
        let b = [UInt8](sample.prefix(4))
        if b.count >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF)) { return true }
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return true }
        if TextEncodingDetector.utf16WithoutBOM(sample) != nil { return true }
        var control = 0
        var hasNUL = false
        sample.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for c in p {
                if c == 0 { hasNUL = true; break }
                if c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D && c != 0x0C && c != 0x1B && c != 0x08 { control += 1 }
                if c == 0x7F { control += 1 }
            }
        }
        if hasNUL { return false }
        if Double(control) / Double(sample.count) > 0.02 { return false }
        if TextEncodingDetector.isValidUTF8(sample) { return true }
        // Legacy encodings: accept if some CJK decoder produces plausible text.
        let enc = TextEncodingDetector.detect(sample)
        return enc.name != "ISO-8859-1" || highBitRatio(sample) < 0.3
    }

    static func highBitRatio(_ d: Data) -> Double {
        guard !d.isEmpty else { return 0 }
        var n = 0
        for c in d where c >= 0x80 { n += 1 }
        return Double(n) / Double(d.count)
    }

    public static func leadingText(_ d: Data, max: Int) -> String {
        let slice = Data(d.prefix(max))
        let enc = TextEncodingDetector.detect(slice)
        return TextEncodingDetector.decode(slice, as: enc)
    }
}
