import Foundation

/// Order-preserving JSON value (Foundation's JSONSerialization loses key order).
public indirect enum JSONValue: Sendable, Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let x), .array(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public var typeName: String {
        switch self {
        case .object(let o): return "对象 {\(o.count)}"
        case .array(let a): return "数组 [\(a.count)]"
        case .string: return "字符串"
        case .number: return "数字"
        case .bool: return "布尔"
        case .null: return "null"
        }
    }
}

public struct JSONParseError: Error, LocalizedError {
    public var message: String
    public var offset: Int
    public var errorDescription: String? { "JSON 解析失败（位置 \(offset)）：\(message)" }
}

/// Recursive-descent parser over UTF-8 bytes. Tolerates // and /* */ comments,
/// trailing commas, and multiple top-level values (JSON Lines).
public struct JSONParser {
    private let b: [UInt8]
    private var i = 0
    private var depth = 0

    public init(data: Data) {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        b = bytes
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var p = JSONParser(data: data)
        var values: [JSONValue] = []
        p.skip()
        while p.i < p.b.count {
            values.append(try p.value())
            p.skip()
            if p.i < p.b.count && p.b[p.i] == UInt8(ascii: ",") { p.i += 1; p.skip() }
        }
        if values.isEmpty { throw JSONParseError(message: "空文档", offset: 0) }
        return values.count == 1 ? values[0] : .array(values)
    }

    private func err(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

    private mutating func skip() {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1; continue }
            if c == UInt8(ascii: "/") && i + 1 < b.count {
                if b[i + 1] == UInt8(ascii: "/") {
                    while i < b.count && b[i] != 0x0A { i += 1 }
                    continue
                }
                if b[i + 1] == UInt8(ascii: "*") {
                    i += 2
                    while i + 1 < b.count && !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    i = min(b.count, i + 2)
                    continue
                }
            }
            break
        }
    }

    private mutating func value() throws -> JSONValue {
        skip()
        guard i < b.count else { throw err("意外结束") }
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw err("嵌套过深") }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [(String, JSONValue)] = []
            skip()
            if i < b.count && b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skip()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("应为键名字符串") }
                let k = try string()
                skip()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("缺少冒号") }
                i += 1
                let v = try value()
                members.append((k, v))
                skip()
                guard i < b.count else { throw err("对象未闭合") }
                if b[i] == UInt8(ascii: ",") {
                    i += 1; skip()
                    if i < b.count && b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    continue
                }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw err("应为 , 或 }")
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JSONValue] = []
            skip()
            if i < b.count && b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try value())
                skip()
                guard i < b.count else { throw err("数组未闭合") }
                if b[i] == UInt8(ascii: ",") {
                    i += 1; skip()
                    if i < b.count && b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    continue
                }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw err("应为 , 或 ]")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            return try literal("true", .bool(true))
        case UInt8(ascii: "f"):
            return try literal("false", .bool(false))
        case UInt8(ascii: "n"):
            return try literal("null", .null)
        default:
            return try number()
        }
    }

    private mutating func literal(_ s: String, _ v: JSONValue) throws -> JSONValue {
        let u = Array(s.utf8)
        guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw err("无效的字面量") }
        i += u.count
        return v
    }

    private mutating func number() throws -> JSONValue {
        let start = i
        while i < b.count {
            let c = b[i]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { i += 1 } else { break }
        }
        guard i > start else { throw err("无法识别的字符") }
        return .number(String(decoding: b[start..<i], as: UTF8.self))
    }

    private mutating func string() throws -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < b.count else { break }
                let e = b[i]
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard i + 4 < b.count, var code = UInt32(String(decoding: b[(i + 1)...(i + 4)], as: UTF8.self), radix: 16) else { throw err("无效的 \\u 转义") }
                    i += 4
                    if (0xD800...0xDBFF).contains(code), i + 6 < b.count, b[i + 1] == UInt8(ascii: "\\"), b[i + 2] == UInt8(ascii: "u"),
                       let low = UInt32(String(decoding: b[(i + 3)...(i + 6)], as: UTF8.self), radix: 16), (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        i += 6
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: out.append(e)
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        throw err("字符串未闭合")
    }
}

extension JSONValue {
    /// Converts property list objects (NSDictionary/NSArray/…) into the same tree shape.
    public static func fromPlist(_ obj: Any) -> JSONValue {
        switch obj {
        case let d as [String: Any]:
            return .object(d.keys.sorted().map { ($0, fromPlist(d[$0]!)) })
        case let a as [Any]:
            return .array(a.map(fromPlist))
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.stringValue)
        case let d as Date:
            return .string(ISO8601DateFormatter().string(from: d))
        case let data as Data:
            let hex = data.prefix(32).map { String(format: "%02x", $0) }.joined()
            return .string("<\(data.count) 字节 \(hex)\(data.count > 32 ? "…" : "")>")
        default:
            return .string(String(describing: obj))
        }
    }
}
