import Foundation

/// Conditional formats Loupe draws: data bars and colour scales. Both depend only on the
/// numbers in their ranges, so they can be worked out without a formula engine.
public struct ConditionalFormat: Sendable, Equatable {
    /// A threshold of a data bar or colour scale (Excel's `<cfvo>`).
    public struct Threshold: Sendable, Equatable {
        public enum Kind: String, Sendable { case min, max, autoMin, autoMax, num, percent, percentile, formula }
        public var kind: Kind
        public var value: Double?
        public init(kind: Kind, value: Double? = nil) { self.kind = kind; self.value = value }

        init(type: String?, val: String?) {
            kind = type.flatMap(Kind.init(rawValue:)) ?? .num
            value = val.flatMap { Double($0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "="))) }
        }
    }

    public struct DataBar: Sendable, Equatable {
        public var low = Threshold(kind: .min), high = Threshold(kind: .max)
        public var color = RGBA(r: 0x63, g: 0x8E, b: 0xC6, a: 255)
        public var border: RGBA?
        public var negativeColor: RGBA?
        public var axisColor: RGBA?
        /// Excel 2010+ bars fade to white unless `gradient="0"`.
        public var gradient = true
        /// Shortest and longest bar, in percent of the cell (Excel 2007 used 10 and 90).
        public var minLength = 10.0, maxLength = 90.0
        public var showValue = true
        public var rightToLeft = false
        public init() {}
    }

    public enum Kind: Sendable, Equatable {
        case dataBar(DataBar)
        /// Two or three stops, low to high.
        case colorScale([(Threshold, RGBA)])

        public static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case (.dataBar(let x), .dataBar(let y)): return x == y
            case (.colorScale(let x), .colorScale(let y)):
                return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: return false
            }
        }
    }

    public var ranges: [MergeRange]
    public var kind: Kind
    /// Lower wins when two rules colour the same cell.
    public var priority: Int
    public init(ranges: [MergeRange], kind: Kind, priority: Int) { self.ranges = ranges; self.kind = kind; self.priority = priority }

    /// "A1:B3 D5" → ranges (single cells too).
    public static func parseRanges(_ sqref: String) -> [MergeRange] {
        sqref.split(separator: " ").compactMap { part in
            let p = String(part)
            if p.contains(":") { return MergeRange.parse(p) }
            return MergeRange.cellRef(p).map { MergeRange(r0: $0.0, c0: $0.1, r1: $0.0, c1: $0.1) }
        }
    }
}

/// How one cell is drawn under its conditional formats.
public struct ConditionalCell: Sendable, Equatable {
    public struct Bar: Sendable, Equatable {
        /// Where the bar starts and ends across the cell, 0…1 from the left.
        public var from: Double, to: Double
        public var negative: Bool
        /// Where the axis is drawn (0…1), when the range has negative and positive values.
        public var axis: Double?
        public var style: ConditionalFormat.DataBar
    }
    public var fill: RGBA?
    public var bar: Bar?
    /// False when a data bar hides the number.
    public var showValue = true
}

public enum ConditionalFormatting {
    /// The look of every cell a data bar or colour scale reaches, keyed like `Sheet.styleIDs`.
    public static func evaluate(_ sheet: Sheet) -> [Int: ConditionalCell] {
        var out: [Int: ConditionalCell] = [:]
        var fillPriority: [Int: Int] = [:]
        for rule in sheet.conditionalFormats.sorted(by: { $0.priority < $1.priority }) {
            // The numbers in the rule's cells. A merged area counts once, by its top-left cell.
            var cells: [(Int, Double)] = []
            for m in rule.ranges {
                let r1 = min(m.r1, sheet.rows.count - 1)
                guard m.r0 <= r1 else { continue }
                for r in m.r0...r1 {
                    let row = sheet.rows[r]
                    for c in m.c0...min(m.c1, max(m.c0, row.count - 1)) where c < row.count {
                        switch row[c] {
                        case .number(let d), .date(let d): cells.append((Sheet.key(r, c), d))
                        default: break
                        }
                    }
                }
            }
            guard !cells.isEmpty else { continue }
            let values = cells.map(\.1).sorted()
            switch rule.kind {
            case .dataBar(let bar):
                var lo = threshold(bar.low, values, isLow: true), hi = threshold(bar.high, values, isLow: false)
                if hi < lo { swap(&lo, &hi) }
                for (k, v) in cells where out[k]?.bar == nil {
                    var cell = out[k] ?? ConditionalCell()
                    cell.bar = barShape(v, lo: lo, hi: hi, style: bar)
                    cell.showValue = bar.showValue
                    out[k] = cell
                }
            case .colorScale(let stops):
                guard stops.count >= 2 else { continue }
                let points = stops.enumerated().map { i, s in
                    (threshold(s.0, values, isLow: i == 0), s.1)
                }
                for (k, v) in cells where fillPriority[k] == nil {
                    var cell = out[k] ?? ConditionalCell()
                    cell.fill = scaleColor(v, points)
                    out[k] = cell
                    fillPriority[k] = rule.priority
                }
            }
        }
        return out
    }

    /// A threshold's value over the range's sorted numbers.
    static func threshold(_ t: ConditionalFormat.Threshold, _ values: [Double], isLow: Bool) -> Double {
        let mn = values.first ?? 0, mx = values.last ?? 0
        switch t.kind {
        case .min: return mn
        case .max: return mx
        // Excel 2010 bars: the automatic ends include zero, so positive bars grow from it.
        case .autoMin: return min(0, mn)
        case .autoMax: return max(0, mx)
        case .num, .formula: return t.value ?? (isLow ? mn : mx)
        case .percent:
            let p = min(100, max(0, t.value ?? (isLow ? 0 : 100)))
            return mn + (mx - mn) * p / 100
        case .percentile:
            // PERCENTILE.INC.
            let p = min(100, max(0, t.value ?? (isLow ? 0 : 100))) / 100
            let pos = p * Double(values.count - 1)
            let i = Int(pos.rounded(.down)), f = pos - Double(i)
            return i + 1 < values.count ? values[i] + (values[i + 1] - values[i]) * f : values[i]
        }
    }

    static func barShape(_ v: Double, lo: Double, hi: Double, style: ConditionalFormat.DataBar) -> ConditionalCell.Bar {
        let minL = min(100, max(0, style.minLength)) / 100, maxL = min(100, max(minL * 100, style.maxLength)) / 100
        if lo < 0 && hi > 0 {
            // Negative and positive values: bars grow both ways from an axis placed in proportion.
            let axis = -lo / (hi - lo)
            if v < 0 {
                let len = min(1, v / lo) * axis
                return .init(from: axis - len, to: axis, negative: true, axis: axis, style: style)
            }
            let len = min(1, v / hi) * (1 - axis)
            return .init(from: axis, to: axis + len, negative: false, axis: axis, style: style)
        }
        if hi <= 0 {
            // All negative: bars grow leftwards from the right edge.
            let frac = lo == hi ? 1 : min(1, max(0, (hi - v) / (hi - lo)))
            let len = minL + (maxL - minL) * frac
            return .init(from: 1 - len, to: 1, negative: true, axis: nil, style: style)
        }
        let frac = hi == lo ? 1 : min(1, max(0, (v - lo) / (hi - lo)))
        let len = minL + (maxL - minL) * frac
        return .init(from: 0, to: len, negative: false, axis: nil, style: style)
    }

    static func scaleColor(_ v: Double, _ points: [(Double, RGBA)]) -> RGBA {
        if v <= points[0].0 { return points[0].1 }
        for i in 1..<points.count {
            let (a, ca) = points[i - 1], (b, cb) = points[i]
            if v <= b {
                let t = b == a ? 1 : (v - a) / (b - a)
                func mix(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded()) }
                return RGBA(r: mix(ca.r, cb.r), g: mix(ca.g, cb.g), b: mix(ca.b, cb.b), a: 255)
            }
        }
        return points[points.count - 1].1
    }
}

/// Collects `<conditionalFormatting>` and the Excel 2010 extension that refines data bars
/// (`<x14:conditionalFormatting>` in the sheet's extLst), matched by rule id.
struct ConditionalFormatReader {
    typealias X14Bar = (id: String?, bar: ConditionalFormat.DataBar, fill: RGBA?)
    let color: ([String: String]) -> RGBA?
    private(set) var rules: [ConditionalFormat] = []
    /// Rules Loupe does not draw (cell value / formula rules, icon sets…).
    private(set) var unsupported = 0

    private var sqref: [MergeRange] = []
    private var inRule = false
    private var ruleType: String?
    private var priority = 0
    private var ruleID: String?
    private var bar: ConditionalFormat.DataBar?
    private var x14Fill: RGBA?
    private var x14Border = false
    private var thresholds: [ConditionalFormat.Threshold] = []
    private var colors: [RGBA] = []
    private var baseIndexByID: [String: Int] = [:]
    private var x14Pending: [X14Bar] = []
    private var text = ""
    private var capturing = false

    init(color: @escaping ([String: String]) -> RGBA?) { self.color = color }

    static func handles(_ name: String) -> Bool {
        name == "conditionalFormatting" || name == "cfRule" || name.hasPrefix("x14:") || name.hasPrefix("xm:")
            || ["dataBar", "colorScale", "cfvo", "color"].contains(name)
    }

    private static func bar(_ a: [String: String]) -> ConditionalFormat.DataBar {
        var b = ConditionalFormat.DataBar()
        b.minLength = a["minLength"].flatMap(Double.init) ?? 10
        b.maxLength = a["maxLength"].flatMap(Double.init) ?? 90
        b.showValue = a["showValue"] != "0" && a["showValue"] != "false"
        return b
    }

    mutating func start(_ name: String, _ a: [String: String]) {
        capturing = name == "x14:id" || name == "xm:f" || name == "xm:sqref"
        text = ""
        switch name {
        case "conditionalFormatting": sqref = ConditionalFormat.parseRanges(a["sqref"] ?? "")
        case "cfRule", "x14:cfRule":
            inRule = true
            ruleType = a["type"]; priority = a["priority"].flatMap(Int.init) ?? 0; ruleID = a["id"]
            thresholds = []; colors = []; bar = nil; x14Fill = nil
        case "dataBar" where inRule: bar = Self.bar(a)
        case "cfvo" where inRule: thresholds.append(.init(type: a["type"], val: a["val"]))
        case "x14:cfvo" where inRule: thresholds.append(.init(type: a["type"], val: nil))
        case "color" where inRule: if let c = color(a) { colors.append(c) }
        case "x14:conditionalFormatting": x14Pending = []
        case "x14:dataBar" where inRule:
            var b = Self.bar(a)
            b.gradient = a["gradient"] != "0" && a["gradient"] != "false"
            b.rightToLeft = a["direction"] == "rightToLeft"
            x14Border = a["border"] == "1" || a["border"] == "true"
            bar = b
        case "x14:fillColor": x14Fill = color(a)
        case "x14:borderColor": if x14Border, let c = color(a) { bar?.border = c }
        case "x14:negativeFillColor": if let c = color(a) { bar?.negativeColor = c }
        case "x14:axisColor": if let c = color(a) { bar?.axisColor = c }
        default: break
        }
    }

    mutating func characters(_ s: String) { if capturing { text += s } }

    mutating func end(_ name: String) {
        capturing = false
        switch name {
        case "x14:id": ruleID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "xm:f":
            if let last = thresholds.indices.last {
                thresholds[last].value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "cfRule":
            inRule = false
            switch ruleType {
            case "dataBar":
                guard var b = bar else { break }
                if thresholds.count >= 2 { b.low = thresholds[0]; b.high = thresholds[1] }
                if let c = colors.first { b.color = c }
                // Excel 2007 bars have no border and always fade.
                if let id = ruleID { baseIndexByID[id] = rules.count }
                rules.append(.init(ranges: sqref, kind: .dataBar(b), priority: priority))
            case "colorScale":
                let n = min(thresholds.count, colors.count)
                if n >= 2 { rules.append(.init(ranges: sqref, kind: .colorScale(Array(zip(thresholds.prefix(n), colors.prefix(n)))), priority: priority)) }
            default: unsupported += 1
            }
        case "x14:cfRule":
            inRule = false
            if ruleType == "dataBar", var b = bar {
                if thresholds.count >= 2 { b.low = thresholds[0]; b.high = thresholds[1] }
                x14Pending.append((ruleID, b, x14Fill))
            } else if baseIndexByID[ruleID ?? ""] == nil {
                unsupported += 1
            }
        case "xm:sqref":
            let ranges = ConditionalFormat.parseRanges(text.trimmingCharacters(in: .whitespacesAndNewlines))
            for p in x14Pending { apply(p, ranges: ranges) }
            x14Pending = []
        default: break
        }
    }

    /// The Excel 2010 description replaces the 2007 one of the same rule (it has the real
    /// lengths, border and gradient), keeping the base rule's colour and priority.
    private mutating func apply(_ p: X14Bar, ranges: [MergeRange]) {
        var b = p.bar
        if let id = p.id, let i = baseIndexByID[id] {
            if case .dataBar(let base) = rules[i].kind {
                b.color = p.fill ?? base.color
                b.showValue = base.showValue && b.showValue
            }
            rules[i].kind = .dataBar(b)
        } else if !ranges.isEmpty {
            if let f = p.fill { b.color = f }
            rules.append(.init(ranges: ranges, kind: .dataBar(b), priority: Int.max / 2))
        }
    }
}
