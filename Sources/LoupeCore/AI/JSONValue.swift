import Foundation

/// A JSON value: tool schemas, tool arguments and wire messages. Encodes with sorted keys so
/// the same request always serialises to the same bytes (prompt caches match on bytes).
public enum AIJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AIJSON])
    case object([String: AIJSON])

    public subscript(key: String) -> AIJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> AIJSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return CellValue.format(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var int: Int? { double.map { Int($0) } }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased())
        default: return nil
        }
    }

    public var array: [AIJSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: AIJSON]? { if case .object(let o) = self { return o }; return nil }

    // MARK: Conversion

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber booleans come through as __NSCFBoolean.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { AIJSON(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { AIJSON(any: $0) })
        default: self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d.rounded() == d && abs(d) < 1e15 ? NSNumber(value: Int64(d)) : NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    /// Parses JSON text; nil when it is not valid JSON.
    public static func parse(_ text: String) -> AIJSON? {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> AIJSON? {
        guard let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return AIJSON(any: o)
    }

    public func data() -> Data {
        (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8)
    }

    public func encoded() -> String { String(decoding: data(), as: UTF8.self) }
}

extension AIJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral elements: AIJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AIJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension AIJSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AIJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: AIJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Small helpers for writing tool parameter schemas.
public enum Schema {
    public static func object(_ props: [String: AIJSON], required: [String] = []) -> AIJSON {
        var o: [String: AIJSON] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }
    public static func string(_ description: String, enum values: [String]? = nil) -> AIJSON {
        var o: [String: AIJSON] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }
    public static func integer(_ description: String) -> AIJSON {
        ["type": "integer", "description": .string(description)]
    }
    public static func boolean(_ description: String) -> AIJSON {
        ["type": "boolean", "description": .string(description)]
    }
    public static func array(_ description: String, items: AIJSON) -> AIJSON {
        ["type": "array", "description": .string(description), "items": items]
    }
}
