import Foundation

public enum HAlign: String, Sendable { case left, center, right, fill, justify, general }
public enum VAlign: String, Sendable { case top, center, bottom }

public struct BorderSides: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = BorderSides(rawValue: 1)
    public static let right = BorderSides(rawValue: 2)
    public static let top = BorderSides(rawValue: 4)
    public static let bottom = BorderSides(rawValue: 8)
}

/// Resolved look of a cell. Index 0 of a workbook's style table is always the default style.
public struct CellStyle: Hashable, Sendable {
    public var fill: RGBA?
    public var fontColor: RGBA?
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var fontSize: Double?
    public var hAlign: HAlign?
    public var vAlign: VAlign?
    public var wrap = false
    public var numberFormat: String?
    public var borders: BorderSides = []
    public var borderColor: RGBA?

    public init() {}

    public var isPlain: Bool { self == CellStyle() }
}

public struct MergeRange: Hashable, Sendable {
    public var r0: Int, c0: Int, r1: Int, c1: Int
    public init(r0: Int, c0: Int, r1: Int, c1: Int) { self.r0 = r0; self.c0 = c0; self.r1 = r1; self.c1 = c1 }

    public func overlaps(_ o: MergeRange) -> Bool { r0 <= o.r1 && o.r0 <= r1 && c0 <= o.c1 && o.c0 <= c1 }
    /// "A1:B3"
    public var ref: String { "\(Sheet.columnName(c0))\(r0 + 1):\(Sheet.columnName(c1))\(r1 + 1)" }

    public static func parse(_ ref: String) -> MergeRange? {
        let parts = ref.split(separator: ":").map(String.init)
        guard parts.count == 2, let a = cellRef(parts[0]), let b = cellRef(parts[1]) else { return nil }
        return MergeRange(r0: min(a.0, b.0), c0: min(a.1, b.1), r1: max(a.0, b.0), c1: max(a.1, b.1))
    }

    static func cellRef(_ s: String) -> (Int, Int)? {
        let t = s.replacingOccurrences(of: "$", with: "")
        let letters = t.prefix { $0.isLetter }
        guard let c = Sheet.columnIndex(String(letters)), let r = Int(t.dropFirst(letters.count)) else { return nil }
        return (r - 1, c)
    }
}

// MARK: - Number formats

public enum NumberFormat {
    /// Built-in format ids (zh-CN flavoured where Excel localises them).
    public static let builtin: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
        5: "¥#,##0;¥-#,##0", 6: "¥#,##0;[Red]¥-#,##0", 7: "¥#,##0.00;¥-#,##0.00", 8: "¥#,##0.00;[Red]¥-#,##0.00",
        9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
        14: "yyyy/m/d", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM",
        20: "h:mm", 21: "h:mm:ss", 22: "yyyy/m/d h:mm",
        27: "yyyy\"年\"m\"月\"", 28: "m\"月\"d\"日\"", 29: "m\"月\"d\"日\"", 30: "m-d-yy", 31: "yyyy\"年\"m\"月\"d\"日\"",
        32: "h\"时\"mm\"分\"", 33: "h\"时\"mm\"分\"ss\"秒\"", 34: "上午/下午h\"时\"mm\"分\"", 35: "上午/下午h\"时\"mm\"分\"ss\"秒\"",
        36: "yyyy\"年\"m\"月\"",
        37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)",
        45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss.0", 48: "##0.0E+0", 49: "@",
        50: "yyyy\"年\"m\"月\"", 51: "m\"月\"d\"日\"", 52: "yyyy\"年\"m\"月\"", 53: "m\"月\"d\"日\"",
        54: "m\"月\"d\"日\"", 55: "上午/下午h\"时\"mm\"分\"", 56: "上午/下午h\"时\"mm\"分\"ss\"秒\"",
        57: "yyyy\"年\"m\"月\"", 58: "m\"月\"d\"日\"",
    ]

    public struct Result: Equatable {
        public var text: String
        public var color: RGBA?
    }

    static let colorNames: [String: RGBA] = [
        "red": RGBA(r: 0xD9, g: 0x2D, b: 0x20), "blue": RGBA(r: 0x00, g: 0x4F, b: 0xC4), "green": RGBA(r: 0x1F, g: 0x7A, b: 0x34),
        "black": RGBA(r: 0, g: 0, b: 0), "white": RGBA(r: 255, g: 255, b: 255), "magenta": RGBA(r: 0xB0, g: 0x1E, b: 0xA6),
        "cyan": RGBA(r: 0x00, g: 0x8B, b: 0x9E), "yellow": RGBA(r: 0xB0, g: 0x8A, b: 0x00),
        "红色": RGBA(r: 0xD9, g: 0x2D, b: 0x20), "蓝色": RGBA(r: 0x00, g: 0x4F, b: 0xC4), "绿色": RGBA(r: 0x1F, g: 0x7A, b: 0x34),
    ]

    /// Splits on top-level ';' (not inside quotes or brackets).
    static func sections(_ code: String) -> [String] {
        var out: [String] = [], cur = ""
        var inQ = false, depth = 0, esc = false
        for ch in code {
            if esc { cur.append(ch); esc = false; continue }
            if ch == "\\" { cur.append(ch); esc = true; continue }
            if ch == "\"" { inQ.toggle() }
            if !inQ { if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 } }
            if ch == ";" && !inQ && depth == 0 { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur)
        return out
    }

    /// Removes [Red]/[$-804]/[>100] tags, returning the colour if any.
    static func stripBrackets(_ s: String) -> (String, RGBA?, Bool) {
        var out = "", color: RGBA?, elapsed = false
        var i = s.startIndex
        var inQ = false
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\"" { inQ.toggle(); out.append(ch); i = s.index(after: i); continue }
            if !inQ && ch == "[", let close = s[i...].firstIndex(of: "]") {
                let tag = String(s[s.index(after: i)..<close])
                let lower = tag.lowercased()
                if let c = colorNames[lower] {
                    color = c
                } else if lower.hasPrefix("$") {
                    // [$¥-804] → "¥"; [$-804] → nothing
                    let sym = tag.dropFirst().prefix { $0 != "-" }
                    if !sym.isEmpty { out += "\"\(sym)\"" }
                } else if ["h", "hh", "m", "mm", "s", "ss"].contains(lower) {
                    elapsed = true
                    out += tag
                }
                i = s.index(after: close)
                continue
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return (out, color, elapsed)
    }

    static func isDateSection(_ s: String) -> Bool {
        var inQ = false, esc = false
        for ch in s.lowercased() {
            if esc { esc = false; continue }
            if ch == "\\" { esc = true; continue }
            if ch == "\"" { inQ.toggle(); continue }
            if !inQ && "ymdhs".contains(ch) { return true }
            if !inQ && (ch == "0" || ch == "#") { return false }
        }
        return false
    }

    public static func format(_ value: CellValue, code: String?) -> Result {
        guard let code, !code.isEmpty, code.lowercased() != "general" else { return Result(text: value.display, color: nil) }
        let secs = sections(code)
        switch value {
        case .text(let t):
            let sec = secs.count >= 4 ? secs[3] : (secs.count == 1 && secs[0].contains("@") ? secs[0] : "@")
            let (s, color, _) = stripBrackets(sec)
            return Result(text: literal(s, replacingAtWith: t), color: color)
        case .number(let d), .date(let d):
            var sec = secs[0]
            var v = d
            if d < 0, secs.count >= 2 { sec = secs[1]; v = abs(d) } else if d == 0, secs.count >= 3 { sec = secs[2] }
            let (s, color, elapsed) = stripBrackets(sec)
            if s.lowercased() == "general" { return Result(text: CellValue.format(v), color: color) }
            if isDateSection(s) { return Result(text: formatDate(v, s, elapsed: elapsed), color: color) }
            if !s.contains(where: { "0#?".contains($0) }) {
                if s.contains("@") { return Result(text: literal(s, replacingAtWith: CellValue.format(v)), color: color) }
                return Result(text: literal(s, replacingAtWith: ""), color: color)
            }
            return Result(text: formatNumber(v, s), color: color)
        default:
            return Result(text: value.display, color: nil)
        }
    }

    /// Converts a format section's literal parts: quoted text, \x escapes, _x spacers, *x fills.
    static func literal(_ s: String, replacingAtWith at: String) -> String {
        var out = ""
        var inQ = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if inQ {
                if ch == "\"" { inQ = false } else { out.append(ch) }
            } else {
                switch ch {
                case "\"": inQ = true
                case "\\": i = s.index(after: i); if i < s.endIndex { out.append(s[i]) }
                case "_": i = s.index(after: i); out.append(" ")
                case "*": i = s.index(after: i)
                case "@": out += at
                default: out.append(ch)
                }
            }
            if i < s.endIndex { i = s.index(after: i) }
        }
        return out
    }

    static func formatNumber(_ value: Double, _ sec: String) -> String {
        // Locate the numeric placeholder span outside quotes.
        let chars = Array(sec)
        var inQ = false
        var first: Int?, last = 0
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                inQ.toggle()
            } else if !inQ && ch == "\\" {
                i += 2; continue
            } else if !inQ && (ch == "_" || ch == "*") {
                i += 2; continue
            } else if !inQ && "0#?.,".contains(ch) {
                if "0#?".contains(ch) || first != nil { if first == nil { first = i }; last = i }
            } else if !inQ && (ch == "E" || ch == "e"), first != nil, i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" {
                last = min(chars.count - 1, i + 1 + chars[(i + 2)...].prefix { "0#".contains($0) }.count)
                i = last + 1
                continue
            }
            i += 1
        }
        guard let start = first else { return CellValue.format(value) }
        let pattern = String(chars[start...last])
        let prefix = String(chars[..<start]), suffix = last + 1 < chars.count ? String(chars[(last + 1)...]) : ""
        var v = value
        let percents = (prefix + suffix).filter { $0 == "%" }.count
        for _ in 0..<percents { v *= 100 }
        // Trailing commas scale by thousands.
        var pat = pattern
        while pat.hasSuffix(",") { pat.removeLast(); v /= 1000 }
        let text: String
        if let eIdx = pat.firstIndex(where: { $0 == "E" || $0 == "e" }) {
            let mant = String(pat[..<eIdx])
            let decimals = mant.split(separator: ".").dropFirst().first.map { $0.filter { "0#".contains($0) }.count } ?? 0
            let expDigits = max(1, pat[eIdx...].filter { $0 == "0" }.count)
            let exp = v == 0 ? 0 : Int(floor(log10(abs(v))))
            let m = v / pow(10, Double(exp))
            text = String(format: "%.\(decimals)f", m) + "E" + (exp < 0 ? "-" : "+") + String(format: "%0\(expDigits)d", abs(exp))
        } else if pat.contains(where: { "\"\\!".contains($0) }) {
            text = formatDigitsWithLiterals(v, pat)
        } else {
            let parts = pat.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let intPart = String(parts[0]), frac = parts.count > 1 ? String(parts[1]) : ""
            let nf = NumberFormatter()
            nf.locale = Locale(identifier: "en_US_POSIX")
            nf.numberStyle = .decimal
            nf.usesGroupingSeparator = intPart.contains(",")
            nf.groupingSeparator = ","
            nf.decimalSeparator = "."
            nf.minimumFractionDigits = frac.filter { $0 == "0" || $0 == "?" }.count
            nf.maximumFractionDigits = frac.filter { "0#?".contains($0) }.count
            nf.minimumIntegerDigits = intPart.filter { $0 == "0" }.count
            nf.roundingMode = .halfUp
            var s = nf.string(from: NSNumber(value: v)) ?? CellValue.format(v)
            if nf.minimumIntegerDigits == 0, s.hasPrefix("0."), intPart.allSatisfy({ $0 == "#" || $0 == "," }) { s.removeFirst() }
            text = s
        }
        return literal(prefix, replacingAtWith: "") + text + literal(suffix, replacingAtWith: "")
    }

    /// A digit pattern with text between placeholders, e.g. Excel's 万 trick `0"."0,`: the quoted
    /// "." is text, not a decimal point, so both 0s are integer digits (4714 shows as 471.4).
    /// Digits fill placeholders from the right; the leftmost placeholder takes any overflow.
    static func formatDigitsWithLiterals(_ value: Double, _ pat: String) -> String {
        enum Token { case digit(Character), literal(String), point }
        var tokens: [Token] = []
        var chars = Array(pat)[...]
        while let ch = chars.popFirst() {
            switch ch {
            case "\"":
                var s = ""
                while let c = chars.popFirst(), c != "\"" { s.append(c) }
                tokens.append(.literal(s))
            case "\\", "!":
                if let c = chars.popFirst() { tokens.append(.literal(String(c))) }
            case "0", "#", "?": tokens.append(.digit(ch))
            case ".": tokens.append(.point)
            case ",": break
            default: tokens.append(.literal(String(ch)))
            }
        }
        let pointAt = tokens.firstIndex {
            if case .point = $0 { return true }; return false
        }
        let intTokens = pointAt.map { Array(tokens[..<$0]) } ?? tokens
        let fracTokens = pointAt.map { Array(tokens[($0 + 1)...]) } ?? []
        let fracCount = fracTokens.filter {
            if case .digit = $0 { return true }; return false
        }.count
        let scaled = (abs(value) * pow(10, Double(fracCount))).rounded(.toNearestOrAwayFromZero)
        var digits = String(format: "%.0f", scaled)
        if digits.count <= fracCount { digits = String(repeating: "0", count: fracCount - digits.count + 1) + digits }
        var intDigits = Array(digits.dropLast(fracCount))
        if intDigits == ["0"] { intDigits = [] }
        let fracDigits = Array(digits.suffix(fracCount))

        let leftmost = intTokens.firstIndex {
            if case .digit = $0 { return true }; return false
        }
        var pieces: [String] = []
        for (index, token) in intTokens.enumerated().reversed() {
            switch token {
            case .literal(let s): pieces.append(s)
            case .point: break
            case .digit(let p):
                if index == leftmost {
                    pieces.append(intDigits.isEmpty ? (p == "0" ? "0" : p == "?" ? " " : "") : String(intDigits))
                    intDigits = []
                } else if let d = intDigits.popLast() {
                    pieces.append(String(d))
                } else {
                    pieces.append(p == "0" ? "0" : p == "?" ? " " : "")
                }
            }
        }
        var out = pieces.reversed().joined()
        if pointAt != nil {
            out += "."
            var next = fracDigits[...]
            for token in fracTokens {
                switch token {
                case .literal(let s): out += s
                case .point: break
                case .digit: out += next.popFirst().map(String.init) ?? "0"
                }
            }
        }
        return (value < 0 && scaled != 0 ? "-" : "") + out
    }

    static func formatDate(_ serial: Double, _ sec: String, elapsed: Bool) -> String {
        let date = CellValue.dateFromSerial(serial)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday, .nanosecond], from: date)
        let lower = sec.lowercased()
        let ampm = lower.contains("am/pm") || lower.contains("a/p") || sec.contains("上午/下午")
        var out = ""
        let chars = Array(sec)
        var i = 0
        var lastWasHour = false
        var inQ = false
        let monthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        func run(_ c: Character) -> Int {
            var n = 0
            while i + n < chars.count && chars[i + n].lowercased() == String(c) { n += 1 }
            return n
        }
        func pad(_ v: Int, _ n: Int) -> String { n >= 2 ? String(format: "%02d", v) : "\(v)" }
        while i < chars.count {
            let ch = chars[i]
            if inQ { if ch == "\"" { inQ = false } else { out.append(ch) }; i += 1; continue }
            switch ch.lowercased() {
            case "\"": inQ = true; i += 1
            case "\\": if i + 1 < chars.count { out.append(chars[i + 1]) }; i += 2
            case "y":
                let n = run("y"); i += n
                out += n <= 2 ? String(format: "%02d", (comps.year ?? 0) % 100) : "\(comps.year ?? 0)"
            case "d":
                let n = run("d"); i += n
                if n >= 3 { out += weekdays[((comps.weekday ?? 1) - 1) % 7] } else { out += pad(comps.day ?? 0, n) }
            case "m":
                let n = run("m")
                // "m" right after an hour or right before seconds means minutes.
                let rest = String(chars[(i + n)...]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":\"分 "))
                let isMinute = n <= 2 && (lastWasHour || rest.hasPrefix("s"))
                i += n
                if isMinute {
                    out += pad(comps.minute ?? 0, n)
                } else if n >= 4 {
                    out += "\(comps.month ?? 1)月"
                } else if n == 3 {
                    out += monthsShort[((comps.month ?? 1) - 1) % 12]
                } else {
                    out += pad(comps.month ?? 0, n)
                }
                lastWasHour = false
                continue
            case "h":
                let n = run("h"); i += n
                var h = comps.hour ?? 0
                if elapsed { h = Int((serial * 24).rounded(.down)) } else if ampm { h = h % 12 == 0 ? 12 : h % 12 }
                out += pad(h, n)
                lastWasHour = true
                continue
            case "s":
                let n = run("s"); i += n
                out += pad(comps.second ?? 0, n)
            case "a":
                if lower[lower.index(lower.startIndex, offsetBy: i)...].hasPrefix("am/pm") {
                    out += (comps.hour ?? 0) < 12 ? "AM" : "PM"; i += 5
                } else if lower[lower.index(lower.startIndex, offsetBy: i)...].hasPrefix("a/p") {
                    out += (comps.hour ?? 0) < 12 ? "A" : "P"; i += 3
                } else {
                    out.append(ch); i += 1
                }
            case "上":
                if String(chars[i...]).hasPrefix("上午/下午") { out += (comps.hour ?? 0) < 12 ? "上午" : "下午"; i += 5 } else { out.append(ch); i += 1 }
            case "_", "*": i += 2
            case "[", "]": i += 1
            case ".":
                // fractional seconds "ss.0"
                let zeros = chars[(i + 1)...].prefix { $0 == "0" }.count
                if zeros > 0 {
                    let frac = Double(comps.nanosecond ?? 0) / 1e9
                    out += String(format: "%.\(zeros)f", frac).dropFirst()
                    i += 1 + zeros
                } else {
                    out.append(ch); i += 1
                }
            default:
                out.append(ch); i += 1
            }
            if ch.lowercased() != "h" { lastWasHour = lastWasHour && (ch == ":" || ch == "\"" || ch == "时") }
        }
        return out
    }
}
