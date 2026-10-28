import Foundation

// MARK: - Tokenizer & parser

enum Tok: Equatable {
    case num(Double), str(String), ident(String), ref(String), op(String), lparen, rparen, comma, eof
}

struct Lexer {
    let s: [Character]
    var i = 0
    init(_ text: String) { s = Array(text) }

    static let refPattern = try! NSRegularExpression(pattern:
        #"^(?:(?:'(?:[^']|'')+'|(?:\[[^\]\[]+\])?[A-Za-z_\p{L}][\w.\p{L}]*)!)?(?:\$?[A-Za-z]{1,3}\$?\d+(?::\$?[A-Za-z]{1,3}\$?\d+)?|\$?[A-Za-z]{1,3}:\$?[A-Za-z]{1,3}|\$?\d+:\$?\d+)"#)

    mutating func all() throws -> [Tok] {
        var out: [Tok] = []
        while true {
            let t = try next()
            out.append(t)
            if t == .eof { return out }
        }
    }

    mutating func next() throws -> Tok {
        while i < s.count, s[i].isWhitespace { i += 1 }
        guard i < s.count else { return .eof }
        let c = s[i]
        // References first (they may start with a letter, digit, $ or quote).
        if c.isLetter || c == "$" || c == "'" || c == "_" || c.isNumber || c == "[" {
            let rest = String(s[i...])
            let ns = rest as NSString
            if let m = Lexer.refPattern.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let txt = ns.substring(with: m.range)
                let after = i + txt.count
                let nextIsParen = after < s.count && s[after] == "("
                let pureNumber = txt.allSatisfy { $0.isNumber }
                // "1:1" is a row range; a bare number is not a reference.
                if !nextIsParen && !pureNumber && !(txt.allSatisfy({ $0.isNumber || $0 == "." })) {
                    // Avoid swallowing names like "LOG10" used as identifiers; refs never continue with a letter.
                    if !(after < s.count && (s[after].isLetter || s[after] == "_")) {
                        i = after
                        return .ref(txt)
                    }
                }
            }
        }
        if c.isNumber || (c == "." && i + 1 < s.count && s[i + 1].isNumber) {
            var j = i
            while j < s.count, s[j].isNumber || s[j] == "." { j += 1 }
            if j < s.count, s[j] == "e" || s[j] == "E" {
                var k = j + 1
                if k < s.count, s[k] == "+" || s[k] == "-" { k += 1 }
                if k < s.count, s[k].isNumber { j = k; while j < s.count, s[j].isNumber { j += 1 } }
            }
            let txt = String(s[i..<j])
            i = j
            guard let d = Double(txt) else { throw FormulaError(message: "无法识别的数字 \(txt)") }
            return .num(d)
        }
        if c == "\"" {
            var j = i + 1
            var out = ""
            while j < s.count {
                if s[j] == "\"" {
                    if j + 1 < s.count, s[j + 1] == "\"" { out.append("\""); j += 2; continue }
                    break
                }
                out.append(s[j]); j += 1
            }
            guard j < s.count else { throw FormulaError(message: "字符串缺少结束引号") }
            i = j + 1
            return .str(out)
        }
        if c.isLetter || c == "_" {
            var j = i
            while j < s.count, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == "." { j += 1 }
            let txt = String(s[i..<j])
            i = j
            return .ident(txt)
        }
        i += 1
        switch c {
        case "(": return .lparen
        case ")": return .rparen
        case ",", ";", "，": return .comma
        case "<":
            if i < s.count, s[i] == "=" { i += 1; return .op("<=") }
            if i < s.count, s[i] == ">" { i += 1; return .op("<>") }
            return .op("<")
        case ">":
            if i < s.count, s[i] == "=" { i += 1; return .op(">=") }
            return .op(">")
        case "+", "-", "*", "/", "^", "&", "=", "%": return .op(String(c))
        default: throw FormulaError(message: "无法识别的字符「\(c)」")
        }
    }
}

public struct FormulaParser {
    var toks: [Tok]
    var p = 0

    public static func parse(_ text: String) throws -> Expr {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("=") { t.removeFirst() }
        var lx = Lexer(t)
        var parser = FormulaParser(toks: try lx.all())
        let e = try parser.comparison()
        guard parser.peek == .eof else { throw FormulaError(message: "公式末尾有多余内容") }
        return e
    }

    var peek: Tok { p < toks.count ? toks[p] : .eof }
    mutating func advance() -> Tok { let t = peek; p += 1; return t }

    mutating func comparison() throws -> Expr {
        var l = try concat()
        while case .op(let o) = peek, ["=", "<>", "<", ">", "<=", ">="].contains(o) {
            _ = advance()
            l = .binary(o, l, try concat())
        }
        return l
    }
    mutating func concat() throws -> Expr {
        var l = try additive()
        while peek == .op("&") { _ = advance(); l = .binary("&", l, try additive()) }
        return l
    }
    mutating func additive() throws -> Expr {
        var l = try multiplicative()
        while case .op(let o) = peek, o == "+" || o == "-" { _ = advance(); l = .binary(o, l, try multiplicative()) }
        return l
    }
    mutating func multiplicative() throws -> Expr {
        var l = try power()
        while case .op(let o) = peek, o == "*" || o == "/" { _ = advance(); l = .binary(o, l, try power()) }
        return l
    }
    mutating func power() throws -> Expr {
        var l = try unary()
        while peek == .op("^") { _ = advance(); l = .binary("^", l, try unary()) }
        return l
    }
    mutating func unary() throws -> Expr {
        if case .op(let o) = peek, o == "-" || o == "+" { _ = advance(); return .unary(o, try unary()) }
        var e = try primary()
        while peek == .op("%") { _ = advance(); e = .percent(e) }
        return e
    }
    mutating func primary() throws -> Expr {
        switch advance() {
        case .num(let d): return .literal(.number(d))
        case .str(let s): return .literal(.text(s))
        case .ref(let r): return try FormulaParser.reference(r)
        case .lparen:
            let e = try comparison()
            guard advance() == .rparen else { throw FormulaError(message: "缺少右括号") }
            return e
        case .ident(let name):
            let upper = name.uppercased()
            if peek == .lparen {
                _ = advance()
                var args: [Expr] = []
                if peek != .rparen {
                    while true {
                        if peek == .comma || peek == .rparen { args.append(.literal(.empty)) }
                        else { args.append(try comparison()) }
                        if peek == .comma { _ = advance(); continue }
                        break
                    }
                }
                guard advance() == .rparen else { throw FormulaError(message: "函数 \(upper) 缺少右括号") }
                return .call(upper.replacingOccurrences(of: "_XLFN.", with: ""), args)
            }
            if upper == "TRUE" { return .literal(.bool(true)) }
            if upper == "FALSE" { return .literal(.bool(false)) }
            throw FormulaError(message: "无法识别的名称「\(name)」")
        case .eof: throw FormulaError(message: "公式不完整")
        default: throw FormulaError(message: "公式语法错误")
        }
    }

    static func reference(_ raw: String) throws -> Expr {
        var sheet: String?
        var body = raw
        if let bang = raw.lastIndex(of: "!") {
            var name = String(raw[..<bang])
            if name.hasPrefix("'") && name.hasSuffix("'") { name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            sheet = name
            body = String(raw[raw.index(after: bang)...])
        }
        let parts = body.split(separator: ":").map(String.init)
        func cell(_ s: String) -> (Int?, Int?, Bool, Bool) {
            var t = Substring(s)
            var absC = false, absR = false
            if t.hasPrefix("$") { absC = true; t = t.dropFirst() }
            let letters = t.prefix { $0.isLetter }
            t = t.dropFirst(letters.count)
            if t.hasPrefix("$") { absR = true; t = t.dropFirst() }
            if letters.isEmpty { absR = absC; absC = false }   // "$1" style row-only part
            let col = letters.isEmpty ? nil : Sheet.columnIndex(String(letters))
            let row = Int(t).map { $0 - 1 }
            return (row, col, absR, absC)
        }
        if parts.count == 1 {
            let (r, c, ar, ac) = cell(parts[0])
            guard let r, let c else { throw FormulaError(message: "无效引用 \(raw)") }
            return .ref(CellRef(sheet: sheet, row: r, col: c, absRow: ar, absCol: ac))
        }
        let (r0, c0, ar0, ac0) = cell(parts[0])
        let (r1, c1, ar1, ac1) = cell(parts[1])
        return .range(RangeRef(sheet: sheet, r0: min(r0 ?? 0, r1 ?? 0), c0: min(c0 ?? 0, c1 ?? 0),
                               r1: r0 == nil ? Int.max : max(r0!, r1 ?? r0!), c1: c0 == nil ? Int.max : max(c0!, c1 ?? c0!),
                               absR0: ar0, absR1: ar1, absC0: ac0, absC1: ac1))
    }
}
