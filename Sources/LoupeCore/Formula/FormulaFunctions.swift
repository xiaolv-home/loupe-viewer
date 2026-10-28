import Foundation

/// The spreadsheet function library (SUM … XLOOKUP) and the coercions it shares.
extension FormulaEngine {
    // MARK: functions

    static let functionNames: [String] = [
        "SUM", "AVERAGE", "COUNT", "COUNTA", "COUNTBLANK", "MIN", "MAX", "MEDIAN", "PRODUCT", "STDEV", "VAR", "LARGE", "SMALL",
        "ROUND", "ROUNDUP", "ROUNDDOWN", "INT", "ABS", "MOD", "POWER", "SQRT", "CEILING", "FLOOR", "SIGN",
        "IF", "IFS", "IFERROR", "IFNA", "AND", "OR", "NOT", "XOR", "SWITCH",
        "CONCAT", "CONCATENATE", "TEXTJOIN", "LEN", "LEFT", "RIGHT", "MID", "UPPER", "LOWER", "PROPER", "TRIM", "SUBSTITUTE",
        "REPLACE", "FIND", "SEARCH", "VALUE", "TEXT", "REPT", "EXACT",
        "VLOOKUP", "HLOOKUP", "XLOOKUP", "INDEX", "MATCH", "XMATCH", "CHOOSE", "ROWS", "COLUMNS",
        "SUMIF", "SUMIFS", "COUNTIF", "COUNTIFS", "AVERAGEIF", "AVERAGEIFS", "MAXIFS", "MINIFS", "SUMPRODUCT",
        "ISBLANK", "ISNUMBER", "ISTEXT", "ISERROR", "ISNA", "ISEVEN", "ISODD",
        "TODAY", "NOW", "DATE", "YEAR", "MONTH", "DAY", "WEEKDAY", "DATEDIF", "EDATE", "EOMONTH", "DAYS", "PI", "RAND", "NA"
    ]

    static func call(_ name: String, _ args: [Expr], _ ctx: FormulaContext) throws -> FValue {
        func arg(_ i: Int) throws -> FValue { i < args.count ? try eval(args[i], ctx) : .empty }
        func n(_ i: Int) throws -> Double? { num(try arg(i).first) }
        func s(_ i: Int) throws -> String { text(try arg(i)) }
        func need(_ k: Int) throws { if args.count < k { throw FormulaError(message: "\(name) 至少需要 \(k) 个参数") } }
        func rounded(_ x: Double, _ d: Int, _ mode: FloatingPointRoundingRule) -> Double {
            let f = pow(10, Double(d)); return (x * f).rounded(mode) / f
        }

        switch name {
        case "SUM", "AVERAGE", "MIN", "MAX", "MEDIAN", "PRODUCT", "STDEV", "VAR", "COUNT":
            if name == "COUNT" {
                var k = 0
                for a in args {
                    let v = try eval(a, ctx)
                    if case .array(let rows) = v { k += rows.joined().filter { if case .number = $0 { return true }; return false }.count }
                    else if num(v) != nil, !{ if case .empty = v { return true }; return false }() { k += 1 }
                }
                return .number(Double(k))
            }
            let (xs, err) = try numbers(args, ctx)
            if let err { return err }
            switch name {
            case "SUM": return .number(xs.reduce(0, +))
            case "PRODUCT": return .number(xs.reduce(1, *))
            case "AVERAGE": return xs.isEmpty ? .error("#DIV/0!") : .number(xs.reduce(0, +) / Double(xs.count))
            case "MIN": return .number(xs.min() ?? 0)
            case "MAX": return .number(xs.max() ?? 0)
            case "MEDIAN":
                guard !xs.isEmpty else { return .error("#NUM!") }
                let s = xs.sorted(); let m = s.count / 2
                return .number(s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2)
            default:
                guard xs.count > 1 else { return .error("#DIV/0!") }
                let mean = xs.reduce(0, +) / Double(xs.count)
                let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count - 1)
                return .number(name == "VAR" ? v : sqrt(v))
            }
        case "LARGE", "SMALL":
            try need(2)
            let (xs, err) = try numbers([args[0]], ctx)
            if let err { return err }
            guard let k = try n(1), k >= 1, Int(k) <= xs.count else { return .error("#NUM!") }
            let sorted = name == "LARGE" ? xs.sorted(by: >) : xs.sorted()
            return .number(sorted[Int(k) - 1])
        case "COUNTA":
            return .number(Double(flatten(try args.map { try eval($0, ctx) }).filter { if case .empty = $0 { return false }; return true }.count))
        case "COUNTBLANK":
            return .number(Double(flatten(try args.map { try eval($0, ctx) }).filter { text($0).isEmpty }.count))

        case "ROUND", "ROUNDUP", "ROUNDDOWN":
            try need(1)
            guard let x = try n(0) else { return .error("#VALUE!") }
            let d = Int(try n(1) ?? 0)
            let mode: FloatingPointRoundingRule = name == "ROUND" ? .toNearestOrAwayFromZero : (name == "ROUNDUP" ? .awayFromZero : .towardZero)
            return .number(rounded(x, d, mode))
        case "INT": guard let x = try n(0) else { return .error("#VALUE!") }; return .number(x.rounded(.down))
        case "ABS": guard let x = try n(0) else { return .error("#VALUE!") }; return .number(abs(x))
        case "SIGN": guard let x = try n(0) else { return .error("#VALUE!") }; return .number(x > 0 ? 1 : (x < 0 ? -1 : 0))
        case "SQRT": guard let x = try n(0), x >= 0 else { return .error("#NUM!") }; return .number(x.squareRoot())
        case "POWER": guard let x = try n(0), let y = try n(1) else { return .error("#VALUE!") }; return .number(pow(x, y))
        case "MOD":
            guard let x = try n(0), let y = try n(1) else { return .error("#VALUE!") }
            guard y != 0 else { return .error("#DIV/0!") }
            return .number(x - y * (x / y).rounded(.down))
        case "CEILING", "FLOOR":
            guard let x = try n(0) else { return .error("#VALUE!") }
            let sig = try n(1) ?? 1
            guard sig != 0 else { return .number(0) }
            return .number((x / sig).rounded(name == "CEILING" ? .up : .down) * sig)
        case "PI": return .number(.pi)
        case "RAND": return .number(Double.random(in: 0..<1))
        case "NA": return .error("#N/A")

        case "IF":
            try need(1)
            let c = try arg(0)
            if c.isError { return c.first }
            return truthy(c) ? (args.count > 1 ? try arg(1) : .bool(true)) : (args.count > 2 ? try arg(2) : .bool(false))
        case "IFS":
            var i = 0
            while i + 1 < args.count {
                if truthy(try arg(i)) { return try arg(i + 1) }
                i += 2
            }
            return .error("#N/A")
        case "SWITCH":
            try need(3)
            let v = try arg(0)
            var i = 1
            while i + 1 < args.count {
                if lookupEquals(v, try arg(i)) { return try arg(i + 1) }
                i += 2
            }
            return i < args.count ? try arg(i) : .error("#N/A")
        case "IFERROR":
            let v = try arg(0)
            return v.isError ? try arg(1) : v
        case "IFNA":
            let v = try arg(0)
            if case .error(let e) = v.first, e == "#N/A" { return try arg(1) }
            return v
        case "AND": return .bool(try flatten(args.map { try eval($0, ctx) }).allSatisfy(truthy))
        case "OR": return .bool(try flatten(args.map { try eval($0, ctx) }).contains(where: truthy))
        case "XOR": return .bool(try flatten(args.map { try eval($0, ctx) }).filter(truthy).count % 2 == 1)
        case "NOT": return .bool(!truthy(try arg(0)))

        case "CONCAT", "CONCATENATE":
            return .text(try flatten(args.map { try eval($0, ctx) }).map(text).joined())
        case "TEXTJOIN":
            try need(3)
            let sep = try s(0)
            let skip = truthy(try arg(1))
            let parts = try flatten(args.dropFirst(2).map { try eval($0, ctx) }).map(text).filter { !skip || !$0.isEmpty }
            return .text(parts.joined(separator: sep))
        case "LEN": return .number(Double(try s(0).count))
        case "LEFT", "RIGHT":
            let t = try s(0)
            let k = max(0, Int(try n(1) ?? 1))
            return .text(name == "LEFT" ? String(t.prefix(k)) : String(t.suffix(k)))
        case "MID":
            try need(3)
            let t = Array(try s(0))
            guard let st = try n(1), let len = try n(2), st >= 1 else { return .error("#VALUE!") }
            let a = min(t.count, Int(st) - 1), b = min(t.count, a + max(0, Int(len)))
            return .text(String(t[a..<b]))
        case "UPPER": return .text(try s(0).uppercased())
        case "LOWER": return .text(try s(0).lowercased())
        case "PROPER": return .text(try s(0).capitalized)
        case "TRIM": return .text(try s(0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        case "REPT": return .text(String(repeating: try s(0), count: max(0, Int(try n(1) ?? 0))))
        case "EXACT": return .bool(try s(0) == s(1))
        case "SUBSTITUTE":
            try need(3)
            return .text(try s(0).replacingOccurrences(of: s(1), with: s(2)))
        case "REPLACE":
            try need(4)
            var t = Array(try s(0))
            guard let st = try n(1), let len = try n(2), st >= 1 else { return .error("#VALUE!") }
            let a = min(t.count, Int(st) - 1), b = min(t.count, a + max(0, Int(len)))
            t.replaceSubrange(a..<b, with: Array(try s(3)))
            return .text(String(t))
        case "FIND", "SEARCH":
            try need(2)
            let needle = try s(0), hay = try s(1)
            let start = max(1, Int(try n(2) ?? 1))
            guard start <= hay.count + 1 else { return .error("#VALUE!") }
            let from = hay.index(hay.startIndex, offsetBy: start - 1)
            let opts: String.CompareOptions = name == "SEARCH" ? [.caseInsensitive] : []
            guard let r = hay.range(of: needle, options: opts, range: from..<hay.endIndex) else { return .error("#VALUE!") }
            return .number(Double(hay.distance(from: hay.startIndex, to: r.lowerBound) + 1))
        case "VALUE":
            guard let d = num(try arg(0)) else { return .error("#VALUE!") }
            return .number(d)
        case "TEXT":
            let v = try arg(0).first
            let fmt = try s(1)
            guard let d = num(v) else { return .text(text(v)) }
            if fmt.contains("y") || fmt.contains("d") || fmt.contains("m") && !fmt.contains("0") {
                let f = DateFormatter()
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = fmt.replacingOccurrences(of: "Y", with: "y").replacingOccurrences(of: "D", with: "d")
                    .replacingOccurrences(of: "m", with: "M").replacingOccurrences(of: "hh:MM", with: "HH:mm").replacingOccurrences(of: ":MM", with: ":mm")
                return .text(f.string(from: CellValue.dateFromSerial(d)))
            }
            if fmt.hasSuffix("%") {
                let decimals = fmt.split(separator: ".").last.map { $0.filter { $0 == "0" }.count } ?? 0
                return .text(String(format: "%.\(fmt.contains(".") ? decimals : 0)f%%", d * 100))
            }
            let decimals = fmt.contains(".") ? (fmt.split(separator: ".").last?.filter { $0 == "0" || $0 == "#" }.count ?? 0) : 0
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.usesGroupingSeparator = fmt.contains(",")
            nf.minimumFractionDigits = fmt.contains(".") ? (fmt.split(separator: ".").last?.filter { $0 == "0" }.count ?? 0) : 0
            nf.maximumFractionDigits = decimals
            return .text(nf.string(from: NSNumber(value: d)) ?? CellValue.format(d))

        case "VLOOKUP", "HLOOKUP":
            try need(3)
            let key = try arg(0).first
            var table = grid(try arg(1))
            if name == "HLOOKUP" { table = transpose(table) }
            guard let idx = try n(2), idx >= 1 else { return .error("#VALUE!") }
            let approximate = args.count > 3 ? truthy(try arg(3)) : true
            var hit: Int?
            if approximate {
                for (i, row) in table.enumerated() {
                    guard let first = row.first else { continue }
                    if case .empty = first { continue }
                    if compare(first, key) <= 0 { hit = i } else { break }
                }
            } else {
                hit = table.firstIndex { ($0.first).map { lookupEquals($0, key) } ?? false }
            }
            guard let h = hit else { return .error("#N/A") }
            let c = Int(idx) - 1
            guard c < table[h].count else { return .error("#REF!") }
            return table[h][c]
        case "XLOOKUP":
            try need(3)
            let key = try arg(0).first
            let look = flatten([try arg(1)])
            let ret = grid(try arg(2))
            let mode = Int(try n(4) ?? 0)
            var hit: Int?
            switch mode {
            case 2:
                let m = criterion(.text(text(key)))
                hit = look.firstIndex(where: m)
            case -1, 1:
                hit = look.firstIndex { lookupEquals($0, key) }
                if hit == nil {
                    var best: (Int, FValue)?
                    for (i, v) in look.enumerated() {
                        let c = compare(v, key)
                        if (mode == -1 && c < 0) || (mode == 1 && c > 0) {
                            if best == nil || (mode == -1 ? compare(v, best!.1) > 0 : compare(v, best!.1) < 0) { best = (i, v) }
                        }
                    }
                    hit = best?.0
                }
            default:
                hit = look.firstIndex { lookupEquals($0, key) }
            }
            guard let h = hit else { return args.count > 3 && !{ if case .empty = (try? arg(3)) ?? .empty { return true }; return false }() ? try arg(3) : .error("#N/A") }
            // Return the matching row of a vertical return array, or column of a horizontal one.
            if ret.count == look.count { return ret[h].count == 1 ? ret[h][0] : .array([ret[h]]) }
            if ret.count == 1, h < ret[0].count { return ret[0][h] }
            if ret.first?.count == look.count { return .array(ret.map { [$0[h]] }) }
            return .error("#VALUE!")
        case "INDEX":
            try need(2)
            let g = grid(try arg(0))
            var r = Int(try n(1) ?? 1), c = args.count > 2 ? Int(try n(2) ?? 1) : 1
            if g.count == 1 && args.count == 2 { c = r; r = 1 }
            guard r >= 1, c >= 1, r <= g.count, c <= (g[r - 1].count) else { return .error("#REF!") }
            return g[r - 1][c - 1]
        case "MATCH", "XMATCH":
            try need(2)
            let key = try arg(0).first
            let look = flatten([try arg(1)])
            let type = Int(try n(2) ?? (name == "XMATCH" ? 0 : 1))
            var hit: Int?
            if type == 0 {
                if case .text(let t) = key, t.contains("*") || t.contains("?") { hit = look.firstIndex(where: criterion(key)) }
                else { hit = look.firstIndex { lookupEquals($0, key) } }
            } else {
                for (i, v) in look.enumerated() {
                    let c = compare(v, key)
                    if (type == 1 && c <= 0) || (type == -1 && c >= 0) { hit = i } else if hit != nil { break }
                }
            }
            return hit.map { .number(Double($0 + 1)) } ?? .error("#N/A")
        case "CHOOSE":
            guard let i = try n(0), i >= 1, Int(i) < args.count else { return .error("#VALUE!") }
            return try arg(Int(i))
        case "ROWS": return .number(Double(grid(try arg(0)).count))
        case "COLUMNS": return .number(Double(grid(try arg(0)).first?.count ?? 0))

        case "SUMIF", "COUNTIF", "AVERAGEIF":
            try need(2)
            let range = flatten([try arg(0)])
            let test = criterion(try arg(1))
            let values = args.count > 2 && name != "COUNTIF" ? flatten([try arg(2)]) : range
            var total = 0.0, count = 0
            for (i, v) in range.enumerated() where test(v) {
                count += 1
                if i < values.count, case .number(let d) = values[i] { total += d }
            }
            switch name {
            case "COUNTIF": return .number(Double(count))
            case "SUMIF": return .number(total)
            default: return count == 0 ? .error("#DIV/0!") : .number(total / Double(count))
            }
        case "SUMIFS", "AVERAGEIFS", "MAXIFS", "MINIFS", "COUNTIFS":
            let isCount = name == "COUNTIFS"
            let firstPair = isCount ? 0 : 1
            guard args.count >= firstPair + 2 else { throw FormulaError(message: "\(name) 参数不足") }
            let values = isCount ? [] : flatten([try arg(0)])
            var pairs: [([FValue], (FValue) -> Bool)] = []
            var i = firstPair
            while i + 1 < args.count {
                pairs.append((flatten([try arg(i)]), criterion(try arg(i + 1))))
                i += 2
            }
            let n0 = pairs.first?.0.count ?? 0
            var picked: [Double] = []
            var count = 0
            for r in 0..<n0 where pairs.allSatisfy({ r < $0.0.count && $0.1($0.0[r]) }) {
                count += 1
                if !isCount, r < values.count, case .number(let d) = values[r] { picked.append(d) }
            }
            switch name {
            case "COUNTIFS": return .number(Double(count))
            case "SUMIFS": return .number(picked.reduce(0, +))
            case "MAXIFS": return .number(picked.max() ?? 0)
            case "MINIFS": return .number(picked.min() ?? 0)
            default: return picked.isEmpty ? .error("#DIV/0!") : .number(picked.reduce(0, +) / Double(picked.count))
            }
        case "SUMPRODUCT":
            let arrays = try args.map { flatten([try eval($0, ctx)]) }
            guard let len = arrays.first?.count, arrays.allSatisfy({ $0.count == len }) else { return .error("#VALUE!") }
            var total = 0.0
            for i in 0..<len {
                var p = 1.0
                for a in arrays { if case .number(let d) = a[i] { p *= d } else if case .bool(let b) = a[i] { p *= b ? 1 : 0 } else { p = 0 } }
                total += p
            }
            return .number(total)

        case "ISBLANK": return .bool(text(try arg(0)).isEmpty)
        case "ISNUMBER": if case .number = try arg(0).first { return .bool(true) }; return .bool(false)
        case "ISTEXT": if case .text(let t) = try arg(0).first { return .bool(!t.isEmpty) }; return .bool(false)
        case "ISERROR": return .bool(try arg(0).isError)
        case "ISNA": if case .error(let e) = try arg(0).first { return .bool(e == "#N/A") }; return .bool(false)
        case "ISEVEN", "ISODD":
            guard let x = try n(0) else { return .error("#VALUE!") }
            let even = Int(x.rounded(.towardZero)) % 2 == 0
            return .bool(name == "ISEVEN" ? even : !even)

        case "TODAY": return .number(CellValue.serial(from: Date()).rounded(.down))
        case "NOW": return .number(CellValue.serial(from: Date()))
        case "DATE":
            guard let y = try n(0), let m = try n(1), let d = try n(2) else { return .error("#VALUE!") }
            var c = DateComponents(); c.year = Int(y); c.month = Int(m); c.day = Int(d)
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            guard let date = cal.date(from: c) else { return .error("#VALUE!") }
            return .number(CellValue.serial(from: date).rounded())
        case "YEAR", "MONTH", "DAY", "WEEKDAY":
            guard let d = dateSerial(try arg(0)) else { return .error("#VALUE!") }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let date = CellValue.dateFromSerial(d)
            switch name {
            case "YEAR": return .number(Double(cal.component(.year, from: date)))
            case "MONTH": return .number(Double(cal.component(.month, from: date)))
            case "DAY": return .number(Double(cal.component(.day, from: date)))
            default: return .number(Double(cal.component(.weekday, from: date)))
            }
        case "DAYS":
            guard let a = dateSerial(try arg(0)), let b = dateSerial(try arg(1)) else { return .error("#VALUE!") }
            return .number((a - b).rounded(.down))
        case "DATEDIF":
            guard let a = dateSerial(try arg(0)), let b = dateSerial(try arg(1)), b >= a else { return .error("#NUM!") }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let unit = try s(2).uppercased()
            let comps = cal.dateComponents([.year, .month, .day], from: CellValue.dateFromSerial(a), to: CellValue.dateFromSerial(b))
            switch unit {
            case "Y": return .number(Double(comps.year ?? 0))
            case "M": return .number(Double((comps.year ?? 0) * 12 + (comps.month ?? 0)))
            default: return .number((b - a).rounded(.down))
            }
        case "EDATE", "EOMONTH":
            guard let a = dateSerial(try arg(0)), let m = try n(1) else { return .error("#VALUE!") }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            guard var d = cal.date(byAdding: .month, value: Int(m), to: CellValue.dateFromSerial(a)) else { return .error("#VALUE!") }
            if name == "EOMONTH", let range = cal.range(of: .day, in: .month, for: d) {
                var c = cal.dateComponents([.year, .month], from: d); c.day = range.count
                d = cal.date(from: c) ?? d
            }
            return .number(CellValue.serial(from: d).rounded(.down))
        default:
            return .error("#NAME?（不支持的函数 \(name)）")
        }
    }

    static func dateSerial(_ v: FValue) -> Double? {
        let v = v.first
        if case .text(let t) = v {
            for fmt in ["yyyy-MM-dd", "yyyy/M/d", "yyyy-M-d", "yyyy年M月d日", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd"] {
                let f = DateFormatter()
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = fmt
                if let d = f.date(from: t) { return CellValue.serial(from: d) }
            }
        }
        return num(v)
    }

    static func transpose(_ g: [[FValue]]) -> [[FValue]] {
        let w = g.map(\.count).max() ?? 0
        return (0..<w).map { c in g.map { c < $0.count ? $0[c] : .empty } }
    }

    /// Names offered for autocompletion / help.
    public static var supportedFunctions: [String] { functionNames }
}
