import Foundation

// MARK: - Evaluation

public struct FormulaContext {
    public var workbook: Workbook
    public var sheet: Int
    /// Rows to shift relative references by (used to fill a formula down a computed column).
    public var rowOffset: Int
    /// Other workbooks a formula may point at with [文件.xlsx]Sheet!A1, keyed by lowercased
    /// file name. The caller loads them (see `externalBookNames`); the engine never reads disk.
    public var externalWorkbooks: [String: Workbook]
    public init(workbook: Workbook, sheet: Int, rowOffset: Int = 0, externalWorkbooks: [String: Workbook] = [:]) {
        self.workbook = workbook
        self.sheet = sheet
        self.rowOffset = rowOffset
        self.externalWorkbooks = externalWorkbooks
    }
}

public enum FormulaEngine {
    public static func evaluate(_ text: String, in ctx: FormulaContext) -> FValue {
        do { return try eval(FormulaParser.parse(text), ctx) }
        catch let e as FormulaError { return .error("#ERROR: " + e.message) }
        catch { return .error("#ERROR") }
    }

    public static func evaluate(_ expr: Expr, in ctx: FormulaContext) -> FValue {
        (try? eval(expr, ctx)) ?? .error("#ERROR")
    }

    /// File names referenced as [文件.xlsx] in a formula (outside string literals).
    public static func externalBookNames(in formula: String) -> [String] {
        var names: [String] = []
        var inString = false
        var current: String?
        for ch in formula {
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "[" { current = ""; continue }
            if ch == "]", let c = current { if !c.isEmpty && !names.contains(c) { names.append(c) }; current = nil; continue }
            current?.append(ch)
        }
        return names
    }

    /// The sheet a reference points at: this workbook's (by name, or the current one) or a sheet
    /// of an external workbook ("[门店表.xlsx]Sheet1"; an empty sheet name means its first sheet).
    static func sheet(_ name: String?, _ ctx: FormulaContext) throws -> Sheet {
        guard let name else { return ctx.workbook.sheets[ctx.sheet] }
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            let book = String(name[name.index(after: name.startIndex)..<close])
            let sheetName = String(name[name.index(after: close)...])
            guard let wb = ctx.externalWorkbooks[book.lowercased()] else {
                throw FormulaError(message: "找不到文件「\(book)」（放在同一文件夹，或用「引用其他文件」选择）")
            }
            if sheetName.isEmpty, let first = wb.sheets.first { return first }
            guard let i = wb.sheetIndex(named: sheetName) else { throw FormulaError(message: "「\(book)」里没有工作表「\(sheetName)」") }
            return wb.sheets[i]
        }
        guard let i = ctx.workbook.sheetIndex(named: name) else { throw FormulaError(message: "找不到工作表「\(name)」") }
        return ctx.workbook.sheets[i]
    }

    static func eval(_ e: Expr, _ ctx: FormulaContext) throws -> FValue {
        switch e {
        case .literal(let v): return v
        case .ref(let r):
            let sh = try sheet(r.sheet, ctx)
            let row = r.absRow ? r.row : r.row + ctx.rowOffset
            return FValue(sh.cell(row, r.col))
        case .range(let r):
            let sh = try sheet(r.sheet, ctx)
            let off = ctx.rowOffset
            let r0 = r.r1 == Int.max ? 0 : (r.absR0 ? r.r0 : r.r0 + off)
            let r1 = r.r1 == Int.max ? sh.rows.count - 1 : (r.absR1 ? r.r1 : r.r1 + off)
            let c1 = r.c1 == Int.max ? sh.columnCount - 1 : r.c1
            guard r1 >= r0, c1 >= r.c0 else { return .array([[]]) }
            let rows = (r0...min(r1, max(r0, sh.rows.count - 1))).map { row in (r.c0...c1).map { FValue(sh.cell(row, $0)) } }
            return .array(rows)
        case .unary(let o, let x):
            let v = try eval(x, ctx).first
            if v.isError { return v }
            guard let n = num(v) else { return .error("#VALUE!") }
            return .number(o == "-" ? -n : n)
        case .percent(let x):
            guard let n = num(try eval(x, ctx).first) else { return .error("#VALUE!") }
            return .number(n / 100)
        case .binary(let o, let a, let b):
            let l = try eval(a, ctx).first, r = try eval(b, ctx).first
            if l.isError { return l }
            if r.isError { return r }
            switch o {
            case "&": return .text(text(l) + text(r))
            case "=", "<>", "<", ">", "<=", ">=":
                let c = compare(l, r)
                switch o {
                case "=": return .bool(c == 0)
                case "<>": return .bool(c != 0)
                case "<": return .bool(c < 0)
                case ">": return .bool(c > 0)
                case "<=": return .bool(c <= 0)
                default: return .bool(c >= 0)
                }
            default:
                guard let x = num(l), let y = num(r) else { return .error("#VALUE!") }
                switch o {
                case "+": return .number(x + y)
                case "-": return .number(x - y)
                case "*": return .number(x * y)
                case "/": return y == 0 ? .error("#DIV/0!") : .number(x / y)
                case "^": return .number(pow(x, y))
                default: return .error("#VALUE!")
                }
            }
        case .call(let name, let args):
            return try call(name, args, ctx)
        }
    }

    // MARK: helpers

    static func num(_ v: FValue) -> Double? {
        switch v {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .text(let s): return CellValue.parseNumber(s)
        case .array(let a): return a.first?.first.flatMap(num)
        case .error: return nil
        }
    }

    static func text(_ v: FValue) -> String { v.first.display }

    static func truthy(_ v: FValue) -> Bool {
        switch v.first {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .text(let s): return s.uppercased() == "TRUE"
        default: return false
        }
    }

    /// Excel-style ordering: numbers < text < booleans; text compares case-insensitively.
    static func compare(_ a: FValue, _ b: FValue) -> Int {
        let a = a.first, b = b.first
        func rank(_ v: FValue) -> Int {
            switch v { case .number, .empty: return 0; case .text: return 1; case .bool: return 2; default: return 3 }
        }
        if case .empty = a, case .text(let s) = b { return s.isEmpty ? 0 : -1 }
        if case .text(let s) = a, case .empty = b { return s.isEmpty ? 0 : 1 }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb ? -1 : 1 }
        switch (a, b) {
        case (.text(let x), .text(let y)):
            let r = x.compare(y, options: [.caseInsensitive, .numeric])
            return r == .orderedAscending ? -1 : (r == .orderedSame ? 0 : 1)
        case (.bool(let x), .bool(let y)): return x == y ? 0 : (!x ? -1 : 1)
        default:
            let x = num(a) ?? 0, y = num(b) ?? 0
            return x < y ? -1 : (x == y ? 0 : 1)
        }
    }

    static func grid(_ v: FValue) -> [[FValue]] {
        if case .array(let a) = v { return a }
        return [[v]]
    }

    static func flatten(_ vals: [FValue]) -> [FValue] {
        vals.flatMap { v -> [FValue] in
            if case .array(let a) = v { return a.flatMap { $0 } }
            return [v]
        }
    }

    /// Numbers for aggregate functions: range cells count only if numeric; direct arguments are coerced.
    static func numbers(_ args: [Expr], _ ctx: FormulaContext) throws -> ([Double], FValue?) {
        var out: [Double] = []
        for a in args {
            let v = try eval(a, ctx)
            if case .array(let rows) = v {
                for c in rows.joined() {
                    if case .error = c { return ([], c) }
                    if case .number(let d) = c { out.append(d) }
                }
            } else {
                if v.isError { return ([], v) }
                if case .empty = v { continue }
                guard let d = num(v) else { return ([], .error("#VALUE!")) }
                out.append(d)
            }
        }
        return (out, nil)
    }

    /// COUNTIF-style criteria: ">=10", "<>x", "=a", "a*", "?b", or a plain value.
    static func criterion(_ c: FValue) -> (FValue) -> Bool {
        let c = c.first
        if case .text(let s) = c {
            var op = "=", rest = s
            for p in [">=", "<=", "<>", ">", "<", "="] where s.hasPrefix(p) { op = p; rest = String(s.dropFirst(p.count)); break }
            let target: FValue = CellValue.parseNumber(rest).map { .number($0) } ?? (rest.isEmpty ? .empty : .text(rest))
            let wildcard = (op == "=" || op == "<>") && (rest.contains("*") || rest.contains("?"))
            let regex: NSRegularExpression? = wildcard ? {
                var pat = "^"
                for ch in rest {
                    switch ch {
                    case "*": pat += ".*"
                    case "?": pat += "."
                    default: pat += NSRegularExpression.escapedPattern(for: String(ch))
                    }
                }
                return try? NSRegularExpression(pattern: pat + "$", options: [.caseInsensitive])
            }() : nil
            return { v in
                if let regex {
                    let t = text(v)
                    let hit = regex.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
                    return op == "=" ? hit : !hit
                }
                if case .empty = target {
                    let blank = text(v).isEmpty
                    return op == "<>" ? !blank : (op == "=" ? blank : false)
                }
                if case .number(let tn) = target {
                    // Numeric criteria only match numeric cells (text that parses as a number counts).
                    let vn: Double?
                    switch v.first {
                    case .number(let d): vn = d
                    case .text(let t): vn = CellValue.parseNumber(t)
                    default: vn = nil
                    }
                    guard let x = vn else { return op == "<>" }
                    switch op {
                    case "=": return x == tn
                    case "<>": return x != tn
                    case ">": return x > tn
                    case "<": return x < tn
                    case ">=": return x >= tn
                    default: return x <= tn
                    }
                }
                let r = compare(v, target)
                switch op {
                case "=": return r == 0
                case "<>": return r != 0
                case ">": return r > 0
                case "<": return r < 0
                case ">=": return r >= 0
                default: return r <= 0
                }
            }
        }
        return { v in compare(v, c) == 0 }
    }

    static func lookupEquals(_ a: FValue, _ b: FValue) -> Bool { compare(a, b) == 0 }
}
