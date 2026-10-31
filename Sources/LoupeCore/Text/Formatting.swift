import Foundation

public enum Fmt {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        // "Zero bytes" is spelled out (in English when the system is): keep it a number.
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n).replacingOccurrences(of: "字节", with: "B")
    }

    public static func exactBytes(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " 字节"
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    public static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    public static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// Classic 16-bytes-per-row hex dump formatting.
public enum HexDump {
    public static let bytesPerRow = 16

    public static func row(_ data: Data, offset: Int) -> (offset: String, hex: String, ascii: String) {
        let end = min(data.count, offset + bytesPerRow)
        guard offset < end else { return (String(format: "%08X", offset), "", "") }
        let slice = data[data.startIndex + offset ..< data.startIndex + end]
        var hex = ""
        var ascii = ""
        hex.reserveCapacity(bytesPerRow * 3 + 1)
        for (i, b) in slice.enumerated() {
            if i == 8 { hex += " " }
            hex += String(format: "%02X ", b)
            ascii.append((0x20..<0x7F).contains(b) ? Character(UnicodeScalar(b)) : "·")
        }
        let pad = bytesPerRow - slice.count
        if pad > 0 {
            hex += String(repeating: "   ", count: pad)
            if slice.count <= 8 { hex += " " }
        }
        return (String(format: "%08X", offset), hex, ascii)
    }
}
