import Foundation

// MARK: - XLSX: inserted / deleted rows and columns

extension XLSXPatcher {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    /// Replaces every match of `re` in `s` with `f(match)` (called in document order).
    private static func replaceMatches(_ s: String, _ re: NSRegularExpression, range: NSRange? = nil,
                                       _ f: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: range ?? NSRange(location: 0, length: ns.length))
        let replacements = matches.map { f($0, ns) }
        let out = NSMutableString(string: s)
        for (m, r) in zip(matches, replacements).reversed() { out.replaceCharacters(in: m.range, with: r) }
        return out as String
    }

    static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Maps a space-separated list of ranges ("A1:B4 D2") through the ops; deleted ranges drop out.
    static func mapRangeList(_ list: String, ops: [StructOp], sheet: String) -> String {
        list.split(separator: " ").compactMap { tok -> String? in
            var t = String(tok)
            for op in ops { t = FormulaRefs.adjusted(t, for: op, targetSheet: sheet, formulaSheet: sheet) }
            return t.contains("#REF!") ? nil : t
        }.joined(separator: " ")
    }

    /// Moves rows/cells of one sheet's XML to their new places and rewrites everything in the
    /// sheet that names cell ranges. Formula cells are rewritten afterwards from the model.
    static func restructure(_ xml: String, ops: [StructOp], sheet: Sheet, prefix: String) throws -> String {
        let p = NSRegularExpression.escapedPattern(for: prefix)
        var doc = xml
        let rowOps = ops.filter(\.isRowOp)
        let colOps = ops.filter { !$0.isRowOp }

        // 1. Rows and cells.
        guard let sdOpen = doc.range(of: "<\(prefix)sheetData"), let sdClose = doc.range(of: "</\(prefix)sheetData>") else {
            if doc.contains("<\(prefix)sheetData") { return doc }   // self-closing: nothing to move
            throw SaveError("工作表结构无法识别")
        }
        let rowRE = regex("<\(p)row\\b([^>]*?)(/>|>(.*?)</\(p)row>)")
        let cellRE = regex("<\(p)c\\b([^>]*?)(/>|>(.*?)</\(p)c>)")
        let rAttr = regex(#"\br="([A-Za-z]*)(\d+)""#)
        let spans = regex(#"\sspans="[^"]*""#)
        var implicitRow = 0
        let dataRange = NSRange(sdOpen.lowerBound..<sdClose.upperBound, in: doc)
        doc = replaceMatches(doc, rowRE, range: dataRange) { m, ns in
            var attrs = ns.substring(with: m.range(at: 1))
            let a = attrs as NSString
            var n = implicitRow + 1
            if let am = rAttr.firstMatch(in: attrs, range: NSRange(location: 0, length: a.length)) {
                n = Int(a.substring(with: am.range(at: 2))) ?? n
            }
            implicitRow = n
            var row: Int? = n - 1
            for op in rowOps { row = row.flatMap(op.map) }
            guard let newRow = row else { return "" }
            attrs = spans.stringByReplacingMatches(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length), withTemplate: "")
            if rAttr.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) != nil {
                attrs = rAttr.stringByReplacingMatches(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length), withTemplate: "r=\"\(newRow + 1)\"")
            } else {
                attrs = " r=\"\(newRow + 1)\"" + attrs
            }
            guard m.range(at: 3).location != NSNotFound else { return "<\(prefix)row\(attrs)/>" }
            let inner = ns.substring(with: m.range(at: 3))
            // Cells: new references, dropped when their column is deleted.
            var implicitCol = -1
            var cells: [(Int, NSRange)] = []
            let ins = inner as NSString
            for cm in cellRE.matches(in: inner, range: NSRange(location: 0, length: ins.length)) {
                let ca = ins.substring(with: cm.range(at: 1)) as NSString
                var col = implicitCol + 1
                if let rm = rAttr.firstMatch(in: ca as String, range: NSRange(location: 0, length: ca.length)) {
                    col = Sheet.columnIndex(ca.substring(with: rm.range(at: 1))) ?? col
                }
                implicitCol = col
                cells.append((col, cm.range))
            }
            let newInner = NSMutableString(string: inner)
            for (col, range) in cells.reversed() {
                var c: Int? = col
                for op in colOps { c = c.flatMap(op.map) }
                guard let nc = c, nc <= FormulaRefs.maxCol else { newInner.replaceCharacters(in: range, with: ""); continue }
                let cellXML = ins.substring(with: range)
                let ref = "r=\"\(Sheet.columnName(nc))\(newRow + 1)\""
                let fixed: String
                if let rm = rAttr.firstMatch(in: cellXML, range: NSRange(location: 0, length: (cellXML as NSString).length)) {
                    fixed = (cellXML as NSString).replacingCharacters(in: rm.range, with: ref)
                } else {
                    fixed = "<\(prefix)c " + ref + String(cellXML.dropFirst(prefix.count + 2))
                }
                newInner.replaceCharacters(in: range, with: fixed)
            }
            return "<\(prefix)row\(attrs)>\(newInner)</\(prefix)row>"
        }

        // 2. Range attributes outside the cells: selections, panes, hyperlinks, filters,
        //    conditional formats and validations. Ranges that vanish are marked for removal.
        let deleted = "__LOUPE_DELETED__"
        let attrRE = regex(#"\b(sqref|ref|activeCell|topLeftCell)="([^"]*)""#)
        let sd2Open = doc.range(of: "<\(prefix)sheetData")!.lowerBound, sd2Close = doc.range(of: "</\(prefix)sheetData>")!.upperBound
        let before = String(doc[..<sd2Open]), data = String(doc[sd2Open..<sd2Close]), after = String(doc[sd2Close...])
        func fixAttrs(_ s: String) -> String {
            replaceMatches(s, attrRE) { m, ns in
                let name = ns.substring(with: m.range(at: 1))
                let mapped = mapRangeList(ns.substring(with: m.range(at: 2)), ops: ops, sheet: sheet.name)
                return "\(name)=\"\(mapped.isEmpty ? deleted : mapped)\""
            }
        }
        var tail = fixAttrs(after)
        let head = fixAttrs(before)
        // Conditional formats / validations whose whole range was deleted disappear.
        tail = replaceMatches(tail, regex("<\(p)conditionalFormatting\\b[^>]*>.*?</\(p)conditionalFormatting>")) { m, ns in
            let block = ns.substring(with: m.range)
            return block.contains("sqref=\"\(deleted)\"") ? "" : block
        }
        tail = replaceMatches(tail, regex("<\(p)dataValidation\\b[^>]*?(/>|>.*?</\(p)dataValidation>)")) { m, ns in
            let block = ns.substring(with: m.range)
            return block.contains("sqref=\"\(deleted)\"") ? "" : block
        }
        tail = replaceMatches(tail, regex("<\(p)dataValidations\\b([^>]*)>(.*?)</\(p)dataValidations>")) { m, ns in
            let inner = ns.substring(with: m.range(at: 2))
            let count = regex("<\(p)dataValidation\\b").numberOfMatches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length))
            if count == 0 { return "" }
            let attrs = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\bcount="\d+""#, with: "count=\"\(count)\"", options: .regularExpression)
            return "<\(prefix)dataValidations\(attrs)>\(inner)</\(prefix)dataValidations>"
        }
        tail = replaceMatches(tail, regex("<\(p)hyperlink\\b[^>]*?ref=\"\(deleted)\"[^>]*?(/>|>.*?</\(p)hyperlink>)")) { _, _ in "" }
        tail = replaceMatches(tail, regex("<\(p)hyperlinks\\b[^>]*>\\s*</\(p)hyperlinks>")) { _, _ in "" }
        // Formulas inside conditional formats and validations.
        tail = replaceMatches(tail, regex("<(\(p)formula[12]?)>(.*?)</\\1>")) { m, ns in
            var f = unescapeXML(ns.substring(with: m.range(at: 2)))
            for op in ops { f = FormulaRefs.adjusted(f, for: op, targetSheet: sheet.name, formulaSheet: sheet.name) }
            let tag = ns.substring(with: m.range(at: 1))
            return "<\(tag)>\(XMLEscape.text(f))</\(tag)>"
        }
        doc = (head + data + tail).replacingOccurrences(of: deleted, with: "A1")

        // 3. Merged cells come straight from the model, which already moved them.
        return rewriteMerges(doc, sheet: sheet, prefix: prefix)
    }

    /// Replaces the sheet's <mergeCells> with the model's merges (adding or removing the element).
    static func rewriteMerges(_ xml: String, sheet: Sheet, prefix: String) -> String {
        let p = NSRegularExpression.escapedPattern(for: prefix)
        let mergesRE = regex("<\(p)mergeCells\\b[^>]*?(/>|>.*?</\(p)mergeCells>)")
        let merges = sheet.merges.map { "<\(prefix)mergeCell ref=\"\($0.ref)\"/>" }
        let mergeXML = merges.isEmpty ? "" : "<\(prefix)mergeCells count=\"\(merges.count)\">\(merges.joined())</\(prefix)mergeCells>"
        let ns = xml as NSString
        if let m = mergesRE.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) {
            return ns.replacingCharacters(in: m.range, with: mergeXML)
        }
        guard !mergeXML.isEmpty else { return xml }
        // The schema puts mergeCells after sheetData/autoFilter and before these.
        for later in ["phoneticPr", "conditionalFormatting", "dataValidations", "hyperlinks", "printOptions", "pageMargins",
                      "pageSetup", "headerFooter", "rowBreaks", "colBreaks", "customProperties", "cellWatches", "ignoredErrors",
                      "smartTags", "drawing", "legacyDrawing", "legacyDrawingHF", "picture", "oleObjects", "controls",
                      "webPublishItems", "tableParts", "extLst"] {
            if let r = xml.range(of: "<\(prefix)\(later)") { return xml.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: mergeXML) }
        }
        if let r = xml.range(of: "</\(prefix)worksheet>") { return xml.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: mergeXML) }
        return xml
    }

    /// Rewrites <cols>: widths move with inserted/deleted columns, and changed widths are set.
    static func updateCols(_ xml: String, ops: [StructOp], widths: Set<Int>, sheet: Sheet, prefix: String) -> String {
        let p = NSRegularExpression.escapedPattern(for: prefix)
        let colsRE = regex("<\(p)cols\\b[^>]*?(/>|>(.*?)</\(p)cols>)")
        let colRE = regex("<\(p)col\\b([^>]*?)/?>")
        let minMax = regex(#"\s(min|max)="(\d+)""#)
        let ns = xml as NSString
        let existing = colsRE.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length))
        var perCol: [Int: String] = [:]
        if let e = existing, e.range(at: 2).location != NSNotFound {
            let inner = ns.substring(with: e.range(at: 2))
            let ins = inner as NSString
            for m in colRE.matches(in: inner, range: NSRange(location: 0, length: ins.length)) {
                let attrs = ins.substring(with: m.range(at: 1))
                let a = attrs as NSString
                var lo = 0, hi = 0
                for mm in minMax.matches(in: attrs, range: NSRange(location: 0, length: a.length)) {
                    let v = Int(a.substring(with: mm.range(at: 2))) ?? 0
                    if a.substring(with: mm.range(at: 1)) == "min" { lo = v } else { hi = v }
                }
                guard lo >= 1, hi >= lo else { continue }
                let rest = minMax.stringByReplacingMatches(in: attrs, range: NSRange(location: 0, length: a.length), withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)
                for c in (lo - 1)...min(hi - 1, FormulaRefs.maxCol) { perCol[c] = rest }
            }
        }
        for op in ops where !op.isRowOp {
            var next: [Int: String] = [:]
            for (c, a) in perCol { if let nc = op.map(c), nc <= FormulaRefs.maxCol { next[nc] = a } }
            if case .insertColumns(let at, let n) = op, at > 0, let left = perCol[at - 1] {
                for i in 0..<n where at + i <= FormulaRefs.maxCol { next[at + i] = left }
            }
            perCol = next
        }
        for c in widths {
            var a = (perCol[c] ?? "").replacingOccurrences(of: #"\s*\b(width|customWidth)="[^"]*""#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let w = sheet.columnWidths[c] ?? sheet.defaultColumnWidth ?? 8.43
            a = (a.isEmpty ? "" : a + " ") + "width=\"\(String(format: "%.2f", w))\" customWidth=\"1\""
            perCol[c] = a
        }
        var out = ""
        var run: (lo: Int, hi: Int, attrs: String)?
        for c in perCol.keys.sorted() {
            let a = perCol[c]!
            if let r = run, r.hi == c - 1, r.attrs == a { run!.hi = c; continue }
            if let r = run { out += "<\(prefix)col min=\"\(r.lo + 1)\" max=\"\(r.hi + 1)\"\(r.attrs.isEmpty ? "" : " " + r.attrs)/>" }
            run = (c, c, a)
        }
        if let r = run { out += "<\(prefix)col min=\"\(r.lo + 1)\" max=\"\(r.hi + 1)\"\(r.attrs.isEmpty ? "" : " " + r.attrs)/>" }
        let cols = out.isEmpty ? "" : "<\(prefix)cols>\(out)</\(prefix)cols>"
        if let e = existing { return ns.replacingCharacters(in: e.range, with: cols) }
        guard !cols.isEmpty, let sd = xml.range(of: "<\(prefix)sheetData") else { return xml }
        return xml.replacingCharacters(in: sd.lowerBound..<sd.lowerBound, with: cols)
    }

    /// Excel tables (ListObjects) keep their own column list; moving columns through one would
    /// corrupt it, so that case is refused. Row changes just move the table's range.
    static func checkTables(work: URL, part: String, ops: [StructOp]) throws {
        let dir = (part as NSString).deletingLastPathComponent
        let relsURL = work.appendingPathComponent(dir).appendingPathComponent("_rels")
            .appendingPathComponent((part as NSString).lastPathComponent + ".rels")
        guard let rels = try? String(contentsOf: relsURL, encoding: .utf8) else { return }
        let relRE = regex(#"<Relationship\b[^>]*Type="[^"]*/table"[^>]*>"#)
        let targetRE = regex(#"Target="([^"]*)""#)
        let rns = rels as NSString
        for m in relRE.matches(in: rels, range: NSRange(location: 0, length: rns.length)) {
            let tag = rns.substring(with: m.range) as NSString
            guard let t = targetRE.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)) else { continue }
            var target = tag.substring(with: t.range(at: 1))
            let url: URL
            if target.hasPrefix("/") { target.removeFirst(); url = work.appendingPathComponent(target) }
            else { url = URL(fileURLWithPath: work.appendingPathComponent(dir).appendingPathComponent(target).path).standardizedFileURL }
            guard var x = try? String(contentsOf: url, encoding: .utf8),
                  let rm = x.range(of: #"<(\w+:)?table\b[^>]*\bref="([^"]*)""#, options: .regularExpression),
                  let refR = x[rm].range(of: #"ref="[^"]*""#, options: .regularExpression),
                  let range = MergeRange.parse(String(x[refR].dropFirst(5).dropLast())) else { continue }
            var r = range
            for op in ops {
                if op.isRowOp {
                    guard let (a, b) = op.mapSpan(r.r0, r.r1), a <= b else { throw SaveError("删除的行包含整个 Excel 表格（表格对象），无法安全保存") }
                    if case .deleteRows(let at, _) = op, at <= r.r0, op.map(r.r0) == nil { throw SaveError("删除的行包含 Excel 表格的标题行，无法安全保存") }
                    r.r0 = a; r.r1 = b
                } else {
                    let touches: Bool
                    switch op {
                    case .insertColumns(let at, _): touches = at > r.c0 && at <= r.c1
                    case .deleteColumns(let at, let n): touches = at <= r.c1 && at + n > r.c0
                    default: touches = false
                    }
                    if touches { throw SaveError("在 Excel 表格（表格对象）内插入或删除列后无法安全写回原文件，请另存为 CSV，或在 Excel 中修改") }
                    guard let (a, b) = op.mapSpan(r.c0, r.c1) else { continue }
                    r.c0 = a; r.c1 = b
                }
            }
            let newRef = "\(Sheet.columnName(r.c0))\(r.r0 + 1):\(Sheet.columnName(r.c1))\(r.r1 + 1)"
            let oldRef = "\(Sheet.columnName(range.c0))\(range.r0 + 1):\(Sheet.columnName(range.c1))\(range.r1 + 1)"
            x = x.replacingOccurrences(of: "ref=\"\(oldRef)\"", with: "ref=\"\(newRef)\"")
            if newRef != oldRef {
                // An autoFilter inside the table covers the same rows.
                x = x.replacingOccurrences(of: #"(<(\w+:)?autoFilter\b[^>]*\bref=")[^"]*""#, with: "$1\(newRef)\"", options: .regularExpression)
            }
            try x.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Defined names (print areas, named ranges) and chart series that point at moved cells.
    static func adjustWorkbookReferences(work: URL, workbook wb: Workbook, structure: [Int: [StructOp]]) {
        func adjust(_ text: String) -> String {
            var f = text
            for (si, ops) in structure where wb.sheets.indices.contains(si) {
                for op in ops { f = FormulaRefs.adjusted(f, for: op, targetSheet: wb.sheets[si].name, formulaSheet: nil) }
            }
            return f
        }
        let wbURL = work.appendingPathComponent("xl/workbook.xml")
        if let w = try? String(contentsOf: wbURL, encoding: .utf8) {
            let fixed = replaceMatches(w, regex(#"<((?:\w+:)?definedName)\b([^>]*)>(.*?)</\1>"#)) { m, ns in
                let tag = ns.substring(with: m.range(at: 1)), attrs = ns.substring(with: m.range(at: 2))
                return "<\(tag)\(attrs)>\(XMLEscape.text(adjust(unescapeXML(ns.substring(with: m.range(at: 3))))))</\(tag)>"
            }
            try? fixed.write(to: wbURL, atomically: true, encoding: .utf8)
        }
        let chartDir = work.appendingPathComponent("xl/charts")
        for f in (try? FileManager.default.contentsOfDirectory(at: chartDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "xml" {
            guard let c = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let fixed = replaceMatches(c, regex(#"<((?:\w+:)?f)>(.*?)</\1>"#)) { m, ns in
                let tag = ns.substring(with: m.range(at: 1))
                return "<\(tag)>\(XMLEscape.text(adjust(unescapeXML(ns.substring(with: m.range(at: 2))))))</\(tag)>"
            }
            if fixed != c { try? fixed.write(to: f, atomically: true, encoding: .utf8) }
        }
    }
}
