import AppKit
import LoupeCore

/// Resolved drawing attributes for one cell style (cached per style and zoom).
struct CellLook {
    var attrs: [NSAttributedString.Key: Any]
    var font: NSFont
    var lineHeight: CGFloat
    var fill: NSColor?
    var align: NSTextAlignment
    var vAlign: VAlign
    var wraps: Bool
    var borders: BorderSides
    var borderColor: NSColor
}

struct CellLookKey: Hashable {
    var style: Int
    var numeric: Bool
    var color: UInt32?
    var flags: UInt8          // 1 error, 2 formula without own colour, 4 unstyled header row
    var align: UInt8          // value-based default alignment
}

/// Drawing: resolved cell looks and the paint pass for a block of rows.
extension SpreadsheetRenderer {
    // MARK: Cell looks

    func look(_ sr: Int, _ c: Int, value: CellValue, colorOverride: RGBA?) -> CellLook {
        let key = Sheet.key(sr, c)
        let styleID = sheet.styleIDs[key] ?? 0
        let style = workbook.style(sheetIndex, sr, c)
        let numeric: Bool = { if case .number = value { return true }; if case .date = value { return true }; return false }()
        var flags: UInt8 = 0
        if case .error = value { flags |= 1 }
        if style?.fontColor == nil && colorOverride == nil && sheet.formulas[key] != nil { flags |= 2 }
        if style == nil && query.headerRowIndex == sr { flags |= 4 }
        let defaultAlign: UInt8 = {
            switch value {
            case .number, .date: return 1
            case .bool, .error: return 2
            default: return 0
            }
        }()
        let ck = CellLookKey(style: styleID, numeric: numeric, color: colorOverride.map { UInt32($0.r) << 24 | UInt32($0.g) << 16 | UInt32($0.b) << 8 | UInt32($0.a) },
                             flags: flags, align: defaultAlign)
        if let hit = lookCache[ck] { return hit }

        // Fill and text colour. Dark "automatic" text on no fill follows the theme so it stays
        // readable in dark mode; text on a fill keeps contrast with that fill. In dark mode,
        // near-white neutral fills become equally subtle tints of the dark sheet.
        var fillRGBA = style?.fill
        var fill = fillRGBA.map(Self.color)
        if isDark, let f = fillRGBA, Self.isNeutralLight(f) {
            let lum = Self.luminance(f)
            fill = lum > 0.985 ? nil : NSColor(white: 1, alpha: CGFloat(min(0.12, (1 - lum) * 1.2)))
            fillRGBA = nil
        }
        if flags & 4 != 0 { fill = Theme.ink.withAlphaComponent(0.045) }
        var textColor: NSColor = Theme.ink
        if let fc = colorOverride ?? style?.fontColor {
            textColor = (fillRGBA == nil && Self.luminance(fc) < 0.25) ? Theme.ink : Self.color(fc)
        } else if let f = fillRGBA {
            textColor = Self.luminance(f) > 0.55 ? NSColor(white: 0.1, alpha: 1) : .white
        }
        if flags & 1 != 0 { textColor = Theme.emberNS }
        if flags & 2 != 0 && fill == nil { textColor = Theme.indigoNS }

        let size = (style?.fontSize.map { max(6, min(48, CGFloat($0))) } ?? 11) * SheetMetrics.fontScale * zoom
        let bold = style?.bold == true || flags & 4 != 0
        var f = numeric ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                        : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if style?.italic == true { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }

        let align: NSTextAlignment
        switch style?.hAlign {
        case .center?: align = .center
        case .right?: align = .right
        case .left?: align = .left
        case .justify?: align = .justified
        default: align = defaultAlign == 1 ? .right : defaultAlign == 2 ? .center : .left
        }
        let wraps = style?.wrap == true
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: textColor, .paragraphStyle: para]
        if style?.underline == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style?.strike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let lk = CellLook(attrs: attrs, font: f, lineHeight: ceil(f.ascender - f.descender + f.leading), fill: fill, align: align,
                          vAlign: style?.vAlign ?? workbook.styles.first?.vAlign ?? .bottom, wraps: wraps, borders: style?.borders ?? [],
                          borderColor: style?.borderColor.map(Self.color) ?? NSColor(white: 0.55, alpha: 1))
        lookCache[ck] = lk
        return lk
    }

    // MARK: Painting

    private struct TextItem {
        var text: String
        var look: CellLook
        var rect: NSRect        // where the text is laid out
        var clip: NSRect
        /// Parts of the text in their own formats (red, bold…), when the cell mixes formats.
        var rich: [RichRun]? = nil
    }

    /// The cell's rich-text runs, if it has them and still holds that text (an edit replaces it).
    private func richRuns(_ sr: Int, _ c: Int, _ value: CellValue) -> [RichRun]? {
        guard let runs = sheet.richText[Sheet.key(sr, c)], case .text(let t) = value, runs.map(\.text).joined() == t else { return nil }
        return runs
    }

    func gridPaint(rows: Range<Int>, colIndices: Range<Int>, dirty: NSRect) {
        Theme.sheet.setFill()
        dirty.fill()
        let L = layout
        guard !rows.isEmpty, !colIndices.isEmpty, rows.upperBound <= visible.count else { return }
        let s = sheet
        let pad = SheetMetrics.padX * zoom
        let x0 = L.xs[colIndices.lowerBound], x1 = L.xs[colIndices.upperBound]
        let y0 = L.ys[rows.lowerBound], y1 = L.ys[rows.upperBound]

        // 1. Grid lines.
        if s.showGridLines {
            Theme.hairline.setFill()
            for i in colIndices { NSRect(x: L.xs[i + 1] - 0.5, y: y0, width: 0.5, height: y1 - y0).fill() }
            for r in rows { NSRect(x: x0, y: L.ys[r + 1] - 0.5, width: x1 - x0, height: 0.5).fill() }
        }

        // 2. Plain cells: fills now, text later. Cells a little outside the dirty columns are
        //    visited too, because their text may overflow into it.
        var texts: [TextItem] = []
        var borders: [(NSRect, BorderSides, NSColor)] = []
        var erase: [(NSRect, NSColor)] = []
        let ext = max(0, colIndices.lowerBound - 24)..<min(L.cols.count, colIndices.upperBound + 24)
        func occupied(_ sr: Int, _ c: Int) -> Bool {
            let k = Sheet.key(sr, c)
            return !s.cell(sr, c).isEmpty || s.formulas[k] != nil || mergeCovered.contains(k) || mergeTopLeft[k] != nil
        }
        for r in rows {
            let sr = visible[r]
            let ry = L.ys[r], rh = L.ys[r + 1] - ry
            for i in ext {
                let c = L.cols[i]
                let key = Sheet.key(sr, c)
                if mergeCovered.contains(key) || activeMerges[key] != nil { continue }
                let inDirty = colIndices.contains(i)
                let value = s.cell(sr, c)
                if !inDirty && (value.isEmpty || !isText(value)) { continue }
                if value.isEmpty && s.styleIDs[key] == nil && query.headerRowIndex != sr { continue }
                let formatted = workbook.formatted(sheetIndex, sr, c)
                let lk = look(sr, c, value: value, colorOverride: formatted.color)
                let rect = NSRect(x: L.xs[i], y: ry, width: L.xs[i + 1] - L.xs[i], height: rh)
                if inDirty {
                    if let f = lk.fill { f.setFill(); rect.fill() }
                    if !lk.borders.isEmpty { borders.append((rect, lk.borders, lk.borderColor)) }
                }
                var text = formatted.text
                if text.isEmpty { continue }
                if !lk.wraps { text = text.replacingOccurrences(of: "\n", with: " ") }
                var clip = rect
                // Text overflows into empty neighbours (left-aligned to the right, right-aligned
                // to the left, centred both ways), like Excel.
                if !lk.wraps, isText(value), CGFloat(text.count) * lk.font.pointSize + pad * 2 > rect.width {
                    let need = ceil((text as NSString).size(withAttributes: [.font: lk.font]).width) + pad * 2
                    if need > rect.width {
                        var lo = i, hi = i
                        var have = rect.width
                        let growRight = lk.align != .right, growLeft = lk.align == .right || lk.align == .center
                        while have < need {
                            var grew = false
                            if growRight, hi + 1 < L.cols.count, hi - i < 30, !occupied(sr, L.cols[hi + 1]) {
                                hi += 1; have += L.xs[hi + 1] - L.xs[hi]; grew = true
                            }
                            if growLeft, have < need, lo > 0, i - lo < 30, !occupied(sr, L.cols[lo - 1]) {
                                lo -= 1; have += L.xs[lo + 1] - L.xs[lo]; grew = true
                            }
                            if !grew { break }
                        }
                        if lk.align == .center {
                            // Keep it centred on its own cell: use the narrower side twice.
                            let left = rect.minX - L.xs[lo], right = L.xs[hi + 1] - rect.maxX
                            let side = min(left, right)
                            if side < (need - rect.width) / 2 && (left > 0 || right > 0) {
                                clip = NSRect(x: L.xs[lo], y: ry, width: L.xs[hi + 1] - L.xs[lo], height: rh)
                            } else {
                                clip = NSRect(x: rect.minX - side, y: ry, width: rect.width + side * 2, height: rh)
                            }
                        } else {
                            clip = NSRect(x: L.xs[lo], y: ry, width: L.xs[hi + 1] - L.xs[lo], height: rh)
                        }
                        // Grid lines under the overflowing text disappear.
                        if s.showGridLines {
                            for j in lo..<hi {
                                let fillUnder = look(sr, L.cols[j], value: .empty, colorOverride: nil).fill
                                erase.append((NSRect(x: L.xs[j + 1] - 0.5, y: ry, width: 0.5, height: rh - 0.5), fillUnder ?? Theme.sheet))
                            }
                        }
                    }
                }
                if !clip.intersects(dirty) { continue }
                texts.append(TextItem(text: text, look: lk, rect: clip.insetBy(dx: pad, dy: 0), clip: clip, rich: richRuns(sr, c, value)))
            }
        }
        for (r, c) in erase { c.setFill(); r.fill() }

        // 3. Merged areas: one fill, one text.
        for mv in mergeViews where mv.vr1 >= rows.lowerBound && mv.vr0 < rows.upperBound {
            guard let rect = mergeRect(mv), rect.intersects(dirty) else { continue }
            let sr = mv.m.r0, c = mv.m.c0
            let value = s.cell(sr, c)
            let formatted = workbook.formatted(sheetIndex, sr, c)
            let lk = look(sr, c, value: value, colorOverride: formatted.color)
            (lk.fill ?? Theme.sheet).setFill()
            rect.fill()
            if s.showGridLines && lk.fill == nil {
                Theme.hairline.setFill()
                NSRect(x: rect.maxX - 0.5, y: rect.minY, width: 0.5, height: rect.height).fill()
                NSRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()
            }
            if !lk.borders.isEmpty { borders.append((rect, lk.borders, lk.borderColor)) }
            var text = formatted.text
            if !lk.wraps { text = text.replacingOccurrences(of: "\n", with: " ") }
            if !text.isEmpty { texts.append(TextItem(text: text, look: lk, rect: rect.insetBy(dx: pad, dy: 0), clip: rect, rich: richRuns(sr, c, value))) }
        }

        // 4. Text.
        let ctx = NSGraphicsContext.current?.cgContext
        for t in texts {
            ctx?.saveGState()
            ctx?.clip(to: t.clip)
            drawText(t.text, t.look, in: t.rect, rich: t.rich)
            ctx?.restoreGState()
        }

        // 5. Cell borders.
        for (rect, b, color) in borders {
            color.setFill()
            if b.contains(.top) { NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill() }
            if b.contains(.bottom) { NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill() }
            if b.contains(.left) { NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill() }
            if b.contains(.right) { NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill() }
        }

        // 6. Charts, pictures and shapes, over the cells and under the selection.
        paintDrawings(dirty: dirty)

        // 7. Find matches, selection and the active cell.
        if !matchKeys.isEmpty {
            NSColor.systemYellow.withAlphaComponent(0.38).setFill()
            for r in rows {
                for i in colIndices where matchKeys.contains(Sheet.key(visible[r], L.cols[i])) {
                    (cellArea(row: r, col: L.cols[i]) ?? .zero).fill(using: .sourceOver)
                }
            }
        }
        for g in rects {
            guard var rr = L.rect(g) else { continue }
            if g.r0 == g.r1 && g.c0 == g.c1, let a = cellArea(row: g.r0, col: g.c0) { rr = a }
            guard rr.intersects(dirty.insetBy(dx: -2, dy: -2)) else { continue }
            if g.cellCount > 1 && mergeArea(row: g.r0, col: g.c0)?.area != g {
                Theme.emberNS.withAlphaComponent(0.11).setFill()
                rr.fill(using: .sourceOver)
            }
            Theme.emberNS.withAlphaComponent(0.85).setStroke()
            let p = NSBezierPath(rect: rr.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
        if active.row < visible.count, let a = cellArea(row: active.row, col: active.col), a.intersects(dirty.insetBy(dx: -2, dy: -2)) {
            Theme.emberNS.setStroke()
            let p = NSBezierPath(rect: a.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }
    }

    private func isText(_ v: CellValue) -> Bool { if case .text = v { return true }; return false }

    /// Rich-text runs on top of the cell's own look: each run overrides only what it sets.
    private func attributed(_ runs: [RichRun], _ lk: CellLook) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let baseFont = lk.font
        for run in runs {
            var attrs = lk.attrs
            var text = run.text
            if !lk.wraps { text = text.replacingOccurrences(of: "\n", with: " ") }
            let size = run.size.map { max(6, min(48, CGFloat($0))) * SheetMetrics.fontScale * zoom } ?? baseFont.pointSize
            let traits = NSFontManager.shared.traits(of: baseFont)
            // Bold cells use the semibold system font, which the bold trait does not report: read the weight.
            let weight = (baseFont.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
            let bold = run.bold ?? (weight > 0.2 || traits.contains(.boldFontMask))
            var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            if run.italic ?? traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attrs[.font] = font
            if let c = run.color {
                // Same rule as whole cells: near-black on no fill follows the theme (dark mode).
                attrs[.foregroundColor] = lk.fill == nil && Self.luminance(c) < 0.25 ? Theme.ink : Self.color(c)
            }
            if let u = run.underline { attrs[.underlineStyle] = u ? NSUnderlineStyle.single.rawValue : nil }
            if let st = run.strike { attrs[.strikethroughStyle] = st ? NSUnderlineStyle.single.rawValue : nil }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    private func drawText(_ text: String, _ lk: CellLook, in rect: NSRect, rich: [RichRun]? = nil) {
        let s = rich.map { attributed($0, lk) } ?? NSAttributedString(string: text, attributes: lk.attrs)
        let inset = 2 * zoom
        if lk.wraps {
            let h = ceil(s.boundingRect(with: NSSize(width: max(1, rect.width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
            let avail = rect.height - inset * 2
            var y: CGFloat
            switch lk.vAlign {
            case .top: y = rect.minY + inset
            case .center: y = rect.midY - h / 2
            case .bottom: y = rect.maxY - inset - h
            }
            if h > avail { y = rect.minY + inset }
            s.draw(with: NSRect(x: rect.minX, y: y, width: rect.width, height: max(h, avail)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            // A rich-text line is as tall as its largest run.
            let lh = rich == nil ? lk.lineHeight : max(lk.lineHeight, ceil(s.size().height))
            var y: CGFloat
            switch lk.vAlign {
            case .top: y = rect.minY + inset
            case .center: y = rect.midY - lh / 2
            case .bottom: y = rect.maxY - inset - lh + 1
            }
            y = max(rect.minY, min(y, rect.maxY - lh))
            s.draw(with: NSRect(x: rect.minX, y: y, width: max(1, rect.width), height: lh), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
