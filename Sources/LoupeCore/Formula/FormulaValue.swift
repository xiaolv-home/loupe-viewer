import Foundation

// MARK: - Values

public indirect enum FValue: Sendable, Equatable {
    case number(Double)
    case text(String)
    case bool(Bool)
    case error(String)
    case empty
    case array([[FValue]])

    init(_ c: CellValue) {
        switch c {
        case .empty: self = .empty
        case .number(let d), .date(let d): self = .number(d)
        case .text(let s): self = .text(s)
        case .bool(let b): self = .bool(b)
        case .error(let e): self = .error(e)
        }
    }

    public var display: String {
        switch self {
        case .number(let d): return CellValue.format(d)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .empty: return ""
        case .array(let a):
            let flat = a.flatMap { $0 }
            if flat.count == 1 { return flat[0].display }
            return flat.prefix(20).map(\.display).joined(separator: ", ") + (flat.count > 20 ? " …" : "")
        }
    }

    /// Converts a formula result into a cell for computed columns.
    public var cell: CellValue {
        switch self {
        case .number(let d): return .number(d)
        case .text(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .error(let e): return .error(e)
        case .empty: return .empty
        case .array(let a): return a.first?.first?.cell ?? .empty
        }
    }

    var first: FValue {
        if case .array(let a) = self { return a.first?.first ?? .empty }
        return self
    }

    var isError: Bool { if case .error = first { return true }; return false }
}

// MARK: - AST

public struct CellRef: Sendable, Equatable {
    public var sheet: String?
    public var row: Int, col: Int
    public var absRow: Bool, absCol: Bool
}

public struct RangeRef: Sendable, Equatable {
    public var sheet: String?
    public var r0: Int, c0: Int, r1: Int, c1: Int     // r1/c1 = Int.max for whole column/row
    public var absR0: Bool, absR1: Bool, absC0: Bool, absC1: Bool
}

public indirect enum Expr: Sendable {
    case literal(FValue)
    case ref(CellRef)
    case range(RangeRef)
    case unary(String, Expr)
    case percent(Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])
}

public struct FormulaError: Error, LocalizedError {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
