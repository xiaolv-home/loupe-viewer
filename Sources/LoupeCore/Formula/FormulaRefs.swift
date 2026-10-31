import Foundation

/// A structural edit of one sheet: rows or columns inserted or deleted (0-based index).
public enum StructOp: Sendable, Equatable {
    case insertRows(at: Int, count: Int)
    case deleteRows(at: Int, count: Int)
    case insertColumns(at: Int, count: Int)
    case deleteColumns(at: Int, count: Int)

    public var isRowOp: Bool {
        switch self {
        case .insertRows, .deleteRows: return true
        case .insertColumns, .deleteColumns: return false
        }
    }

    /// New index along the op's axis, or nil when that row/column is deleted.
    public func map(_ i: Int) -> Int? {
        switch self {
        case .insertRows(let at, let n), .insertColumns(let at, let n):
            return i >= at ? i + n : i
        case .deleteRows(let at, let n), .deleteColumns(let at, let n):
            return i < at ? i : (i >= at + n ? i - n : nil)
        }
    }

    /// New bounds of a span along the op's axis (a range grows when rows are inserted inside it
    /// and shrinks when part of it is deleted); nil when the whole span is deleted.
    public func mapSpan(_ lo: Int, _ hi: Int) -> (Int, Int)? {
        switch self {
        case .insertRows(let at, let n), .insertColumns(let at, let n):
            return (lo >= at ? lo + n : lo, hi >= at ? hi + n : hi)
        case .deleteRows(let at, let n), .deleteColumns(let at, let n):
            let end = at + n
            if lo >= at && hi < end { return nil }
            let nlo = lo < at ? lo : (lo >= end ? lo - n : at)
            let nhi = hi < at ? hi : (hi >= end ? hi - n : at - 1)
            return nlo <= nhi ? (nlo, nhi) : nil
        }
    }
}

/// Finds and rewrites cell references inside formula text (A1, $B$2, C3:D9, E:E, 4:6,
/// Sheet!A1, 'My sheet'!A1:B2) while leaving strings, functions and names untouched.
public enum FormulaRefs {
    public static let maxRow = 1_048_575
    public static let maxCol = 16_383

    public struct Ref: Equatable {
        public enum Kind { case cells, rows, cols }
        public var kind: Kind
        public var r0 = 0, r1 = 0, c0 = 0, c1 = 0
        public var absR0 = false, absR1 = false, absC0 = false, absC1 = false
        public var isRange = false
    }

    /// Shifts relative references by a row/column offset, as when a formula is copied
    /// (fill down, shared formulas). References pushed off the sheet become #REF!.
    public static func shifted(_ formula: String, rows dr: Int, cols dc: Int) -> String {
        guard dr != 0 || dc != 0 else { return formula }
        return rewrite(formula) { _, ref in
            var r = ref
            if r.kind != .cols {
                if !r.absR0 { r.r0 += dr }
                if !r.absR1 { r.r1 += dr }
            }
            if r.kind != .rows {
                if !r.absC0 { r.c0 += dc }
                if !r.absC1 { r.c1 += dc }
            }
            let rowsOK = r.kind == .cols || (r.r0 >= 0 && r.r1 >= 0 && r.r0 <= maxRow && r.r1 <= maxRow)
            let colsOK = r.kind == .rows || (r.c0 >= 0 && r.c1 >= 0 && r.c0 <= maxCol && r.c1 <= maxCol)
            return rowsOK && colsOK ? r : nil
        }
    }

    /// Adjusts references to `targetSheet` after rows/columns were inserted or deleted there.
    /// `formulaSheet` is the sheet holding the formula (unqualified references point at it);
    /// nil for workbook-level text such as defined names, where only qualified references count.
    public static func adjusted(_ formula: String, for op: StructOp, targetSheet: String, formulaSheet: String?) -> String {
        rewrite(formula) { sheet, ref in
            let name = sheet ?? formulaSheet
            guard let name, name.caseInsensitiveCompare(targetSheet) == .orderedSame else { return ref }
            var r = ref
            if op.isRowOp {
                if r.kind == .cols { return r }
                if r.isRange {
                    guard let (a, b) = op.mapSpan(r.r0, r.r1) else { return nil }
                    r.r0 = a; r.r1 = b
                } else {
                    guard let a = op.map(r.r0) else { return nil }
                    r.r0 = a; r.r1 = a
                }
                guard r.r1 <= maxRow else { return nil }
            } else {
                if r.kind == .rows { return r }
                if r.isRange {
                    guard let (a, b) = op.mapSpan(r.c0, r.c1) else { return nil }
                    r.c0 = a; r.c1 = b
                } else {
                    guard let a = op.map(r.c0) else { return nil }
                    r.c0 = a; r.c1 = a
                }
                guard r.c1 <= maxCol else { return nil }
            }
            return r
        }
    }

    /// Calls `transform(sheetPrefix, ref)` for every reference; nil turns it into #REF!.
    /// Unchanged references keep their original spelling.
    public static func rewrite(_ formula: String, _ transform: (String?, Ref) -> Ref?) -> String {
        let chars = Array(formula)
        let n = chars.count
        var out = ""
        out.reserveCapacity(formula.utf8.count + 8)
        var i = 0
        // Set right after "[book]": the sheet!ref that follows belongs to another file.
        var external = false
        func isWord(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "." || c == "$" || c == "\\" || (c.unicodeScalars.first?.value ?? 0) > 127
        }
        while i < n {
            let ch = chars[i]
            if ch == "\"" {
                var j = i + 1
                while j < n {
                    if chars[j] == "\"" { if j + 1 < n && chars[j + 1] == "\"" { j += 2; continue }; break }
                    j += 1
                }
                out += String(chars[i...min(j, n - 1)])
                i = j + 1
                continue
            }
            if ch == "#" {
                var j = i + 1
                while j < n, chars[j].isLetter || chars[j] == "/" || chars[j] == "0" || chars[j] == "!" || chars[j] == "?" { j += 1 }
                out += String(chars[i..<j])
                i = j
                continue
            }
            if ch == "[" {
                var depth = 0, j = i
                while j < n {
                    if chars[j] == "[" { depth += 1 } else if chars[j] == "]" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                out += String(chars[i...min(j, n - 1)])
                i = j + 1
                external = i < n && (isWord(chars[i]) || chars[i] == "'")
                continue
            }
            let start = i
            let isExternal = external
            external = false
            var sheet: String?
            var j = i
            if ch == "'" {
                var k = i + 1
                var name = ""
                while k < n {
                    if chars[k] == "'" { if k + 1 < n && chars[k + 1] == "'" { name.append("'"); k += 2; continue }; break }
                    name.append(chars[k])
                    k += 1
                }
                guard k + 1 < n, chars[k + 1] == "!" else { out.append(ch); i += 1; continue }
                sheet = name
                j = k + 2
            } else if isWord(ch) {
                var k = i
                while k < n, isWord(chars[k]) { k += 1 }
                if k < n, chars[k] == "!" { sheet = String(chars[i..<k]); j = k + 1 }
            } else {
                out.append(ch)
                i += 1
                continue
            }
            if let (ref, end) = parseRef(chars, j) {
                if isExternal {
                    out += String(chars[start..<end])
                } else if let new = transform(sheet, ref) {
                    out += new == ref ? String(chars[start..<end]) : String(chars[start..<j]) + format(new)
                } else {
                    out += String(chars[start..<j]) + "#REF!"
                }
                i = end
            } else {
                var k = j
                while k < n, isWord(chars[k]) { k += 1 }
                k = max(k, start + 1)
                out += String(chars[start..<k])
                i = k
            }
        }
        return out
    }

    public static func format(_ r: Ref) -> String {
        func col(_ c: Int, _ abs: Bool) -> String { (abs ? "$" : "") + Sheet.columnName(c) }
        func row(_ r: Int, _ abs: Bool) -> String { (abs ? "$" : "") + "\(r + 1)" }
        switch r.kind {
        case .cols: return col(r.c0, r.absC0) + ":" + col(r.c1, r.absC1)
        case .rows: return row(r.r0, r.absR0) + ":" + row(r.r1, r.absR1)
        case .cells:
            let a = col(r.c0, r.absC0) + row(r.r0, r.absR0)
            return r.isRange ? a + ":" + col(r.c1, r.absC1) + row(r.r1, r.absR1) : a
        }
    }

    private enum Part { case cell(Int, Bool, Int, Bool), col(Int, Bool), row(Int, Bool) }

    /// One side of a reference at `i`: $?COL$?ROW, $?COL or $?ROW.
    private static func parsePart(_ c: [Character], _ i: Int) -> (Part, Int)? {
        var j = i
        let n = c.count
        var absC = false
        if j < n, c[j] == "$" { absC = true; j += 1 }
        var letters = 0, col = 0
        while j < n, let a = c[j].asciiValue, (a >= 65 && a <= 90) || (a >= 97 && a <= 122), letters < 4 {
            col = col * 26 + Int((a >= 97 ? a - 32 : a) - 64)
            letters += 1
            j += 1
        }
        if letters > 3 { return nil }
        var absR = false
        var k = j
        if k < n, c[k] == "$" { absR = true; k += 1 }
        var digits = 0, row = 0
        while k < n, let d = c[k].wholeNumberValue, c[k].isASCII, digits < 8 { row = row * 10 + d; digits += 1; k += 1 }
        if letters > 0 && digits > 0 {
            guard col - 1 <= maxCol, row >= 1, row - 1 <= maxRow else { return nil }
            return (.cell(col - 1, absC, row - 1, absR), k)
        }
        if letters > 0 && !absR { guard col - 1 <= maxCol else { return nil }; return (.col(col - 1, absC), j) }
        if letters == 0 && digits > 0 && !absC {
            // A lone "$" belongs to the row ("$3"), not the column.
            guard row >= 1, row - 1 <= maxRow else { return nil }
            return (.row(row - 1, absR), k)
        }
        if letters == 0 && digits > 0 && absC && !absR {
            guard row >= 1, row - 1 <= maxRow else { return nil }
            return (.row(row - 1, true), k)
        }
        return nil
    }

    private static func parseRef(_ c: [Character], _ i: Int) -> (Ref, Int)? {
        guard let (a, e1) = parsePart(c, i) else { return nil }
        var end = e1
        var b: Part?
        if end < c.count, c[end] == ":", let (p, e2) = parsePart(c, end + 1) { b = p; end = e2 }
        // A reference must not run into more name characters or a function call.
        if end < c.count {
            let nx = c[end]
            if nx == "(" || nx.isLetter || nx.isNumber || nx == "_" || nx == "." || nx == "!" { return nil }
        }
        var r: Ref
        switch (a, b) {
        case (.cell(let c0, let ac0, let r0, let ar0), nil):
            r = Ref(kind: .cells, r0: r0, r1: r0, c0: c0, c1: c0, absR0: ar0, absR1: ar0, absC0: ac0, absC1: ac0)
        case (.cell(let c0, let ac0, let r0, let ar0), .cell(let c1, let ac1, let r1, let ar1)?):
            r = Ref(kind: .cells, r0: r0, r1: r1, c0: c0, c1: c1, absR0: ar0, absR1: ar1, absC0: ac0, absC1: ac1, isRange: true)
        case (.col(let c0, let ac0), .col(let c1, let ac1)?):
            r = Ref(kind: .cols, c0: c0, c1: c1, absC0: ac0, absC1: ac1, isRange: true)
        case (.row(let r0, let ar0), .row(let r1, let ar1)?):
            r = Ref(kind: .rows, r0: r0, r1: r1, absR0: ar0, absR1: ar1, isRange: true)
        default:
            return nil
        }
        return (r, end)
    }
}

extension Workbook {
    /// Inserts or deletes rows/columns of one sheet: cells, formulas, styles, sizes, merges and
    /// hidden flags move along, and every formula in the workbook that points at the moved
    /// cells is rewritten (deleted targets become #REF!). Inserted rows/columns take the
    /// formatting of the row above / column to the left, like Excel.
    public mutating func apply(_ op: StructOp, sheet si: Int) {
        guard sheets.indices.contains(si) else { return }
        var s = sheets[si]
        switch op {
        case .insertRows(let at, let n):
            if at < s.rows.count { s.rows.insert(contentsOf: Array(repeating: [], count: n), at: at) }
        case .deleteRows(let at, let n):
            if at < s.rows.count { s.rows.removeSubrange(at..<min(s.rows.count, at + n)) }
        case .insertColumns(let at, let n):
            for r in s.rows.indices where s.rows[r].count > at { s.rows[r].insert(contentsOf: repeatElement(.empty, count: n), at: at) }
            if at < s.columnCount { s.columnCount += n }
        case .deleteColumns(let at, let n):
            for r in s.rows.indices where s.rows[r].count > at { s.rows[r].removeSubrange(at..<min(s.rows[r].count, at + n)) }
            if at < s.columnCount { s.columnCount -= min(n, s.columnCount - at) }
        }
        let rowOp = op.isRowOp
        func mapKey(_ k: Int) -> Int? {
            let r = k / 16384, c = k % 16384
            if rowOp { return op.map(r).flatMap { $0 <= FormulaRefs.maxRow ? Sheet.key($0, c) : nil } }
            return op.map(c).flatMap { $0 <= FormulaRefs.maxCol ? Sheet.key(r, $0) : nil }
        }
        func remap<V>(_ d: [Int: V]) -> [Int: V] {
            var out: [Int: V] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d { if let nk = mapKey(k) { out[nk] = v } }
            return out
        }
        func remapIndex<V>(_ d: [Int: V]) -> [Int: V] {
            var out: [Int: V] = [:]
            for (k, v) in d { if let nk = op.map(k) { out[nk] = v } }
            return out
        }
        let oldStyles = s.styleIDs
        s.formulas = remap(s.formulas)
        s.styleIDs = remap(s.styleIDs)
        if rowOp {
            s.rowHeights = remapIndex(s.rowHeights)
            s.customHeightRows = Set(s.customHeightRows.compactMap(op.map))
            s.hiddenRows = Set(s.hiddenRows.compactMap(op.map))
        } else {
            s.columnWidths = remapIndex(s.columnWidths)
            s.hiddenColumns = Set(s.hiddenColumns.compactMap(op.map))
        }
        s.merges = s.merges.compactMap { m in
            var m = m
            if rowOp {
                guard let (a, b) = op.mapSpan(m.r0, m.r1) else { return nil }
                m.r0 = a; m.r1 = b
            } else {
                guard let (a, b) = op.mapSpan(m.c0, m.c1) else { return nil }
                m.c0 = a; m.c1 = b
            }
            return m.r0 == m.r1 && m.c0 == m.c1 ? nil : m
        }
        s.richText = remap(s.richText)
        // Conditional formats cover the same cells as before (growing or shrinking with them).
        for i in s.conditionalFormats.indices {
            s.conditionalFormats[i].ranges = s.conditionalFormats[i].ranges.compactMap { m in
                var m = m
                if rowOp {
                    guard let (a, b) = op.mapSpan(m.r0, m.r1) else { return nil }
                    m.r0 = a; m.r1 = b
                } else {
                    guard let (a, b) = op.mapSpan(m.c0, m.c1) else { return nil }
                    m.c0 = a; m.c1 = b
                }
                return m
            }
        }
        s.conditionalFormats.removeAll { $0.ranges.isEmpty }
        // Formatting of the neighbour carries over to inserted rows / columns.
        switch op {
        case .insertRows(let at, let n) where at > 0:
            for (k, id) in oldStyles where k / 16384 == at - 1 {
                for i in 0..<n { s.styleIDs[Sheet.key(at + i, k % 16384)] = id }
            }
            if let w = s.rowHeights[at - 1], s.customHeightRows.contains(at - 1) {
                for i in 0..<n { s.rowHeights[at + i] = w; s.customHeightRows.insert(at + i) }
            }
        case .insertColumns(let at, let n) where at > 0:
            for (k, id) in oldStyles where k % 16384 == at - 1 {
                for i in 0..<n where at + i <= FormulaRefs.maxCol { s.styleIDs[Sheet.key(k / 16384, at + i)] = id }
            }
            if let w = s.columnWidths[at - 1] { for i in 0..<n { s.columnWidths[at + i] = w } }
        default: break
        }
        sheets[si] = s
        let target = s.name
        for i in sheets.indices where !sheets[i].formulas.isEmpty {
            let own = sheets[i].name
            for (k, f) in sheets[i].formulas {
                let g = FormulaRefs.adjusted(f, for: op, targetSheet: target, formulaSheet: own)
                if g != f { sheets[i].formulas[k] = g }
            }
        }
    }
}
