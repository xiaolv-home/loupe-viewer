import AppKit
import LoupeCore

/// Draws a resolved Office chart into a rectangle of a flipped view (y grows downwards).
/// Not tied to the spreadsheet: anything that has a ResolvedChart and a rectangle can use it.
@MainActor
struct ChartPainter {
    let chart: ResolvedChart
    /// Zoom: 1 = the chart's own size in Excel's screen pixels.
    let scale: CGFloat

    private var spec: ChartSpec { chart.spec }
    private var theme: DrawingTheme { spec.theme }

    // MARK: Entry

    func draw(in rect: CGRect) {
        guard rect.width > 4, rect.height > 4, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        (spec.background.map(ns) ?? .white).setFill()
        rect.fill()
        NSColor(white: 0.85, alpha: 1).setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()

        var area = rect.insetBy(dx: 10 * scale, dy: 8 * scale)
        if let title = chart.title, !title.isEmpty {
            let t = spec.title
            let font = NSFont.systemFont(ofSize: px(t?.size ?? 14), weight: (t?.bold ?? true) ? .semibold : .regular)
            let h = drawText(title, font: font, color: t?.color.map(ns) ?? NSColor(white: 0.25, alpha: 1),
                             in: CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * 0.3), align: .center)
            area.origin.y += h + 6 * scale
            area.size.height -= h + 6 * scale
        }
        if let legend = spec.legend, !legendEntries.isEmpty, area.height > 30 * scale {
            area = drawLegend(legend, in: area)
        }
        guard area.width > 20, area.height > 20 else { ctx.restoreGState(); return }
        let radial = chart.plots.filter { $0.plot.kind == .pie || $0.plot.kind == .doughnut }
        let radar = chart.plots.filter { $0.plot.kind == .radar }
        let cartesian = chart.plots.filter { ![.pie, .doughnut, .radar].contains($0.plot.kind) }
        if let p = radial.first, cartesian.isEmpty { drawPie(p, in: area) }
        else if let p = radar.first, cartesian.isEmpty { drawRadar(p, in: area) }
        else if !cartesian.isEmpty { drawCartesian(cartesian, in: area) }
        else { drawEmpty(in: area) }
        ctx.restoreGState()
    }

    // MARK: Helpers

    private func px(_ pt: Double) -> CGFloat { CGFloat(pt) * 4 / 3 * scale }
    private var labelFont: NSFont { NSFont.systemFont(ofSize: px(9)) }
    private var labelColor: NSColor { NSColor(white: 0.35, alpha: 1) }

    private func ns(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    private func color(_ s: ResolvedSeries) -> NSColor {
        ns(s.series.fill ?? s.series.line ?? theme.seriesColor(s.index))
    }

    private func lineColor(_ s: ResolvedSeries) -> NSColor {
        ns(s.series.line ?? s.series.fill ?? theme.seriesColor(s.index))
    }

    @discardableResult
    private func drawText(_ s: String, font: NSFont, color: NSColor, in r: CGRect, align: NSTextAlignment) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = ceil(str.boundingRect(with: CGSize(width: max(1, r.width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
        str.draw(with: CGRect(x: r.minX, y: r.minY, width: r.width, height: min(h, r.height)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(h, r.height)
    }

    private func size(_ s: String, _ font: NSFont) -> CGSize { (s as NSString).size(withAttributes: [.font: font]) }

    private func label(_ s: String, at p: CGPoint, anchor: (x: CGFloat, y: CGFloat), font: NSFont? = nil, color: NSColor? = nil) {
        let f = font ?? labelFont
        let sz = size(s, f)
        (s as NSString).draw(at: CGPoint(x: p.x - sz.width * anchor.x, y: p.y - sz.height * anchor.y),
                             withAttributes: [.font: f, .foregroundColor: color ?? labelColor])
    }

    private func format(_ v: Double, _ code: String?) -> String {
        guard let code, !code.isEmpty, code != "General" else {
            if abs(v) >= 10000 || v == v.rounded() { return NumberFormat.format(.number(v), code: "#,##0").text }
            return NumberFormat.format(.number(v), code: abs(v) < 1 ? "0.###" : "#,##0.##").text
        }
        return NumberFormat.format(.number(v), code: code).text
    }

    private func drawEmpty(in r: CGRect) {
        label("没有可画的数据", at: CGPoint(x: r.midX, y: r.midY), anchor: (0.5, 0.5))
    }

    // MARK: Legend

    private var legendEntries: [(String, NSColor, Bool)] {
        let hidden = spec.legend?.hiddenEntries ?? []
        if chart.plots.count == 1, let p = chart.plots.first, p.plot.varyColors || p.plot.kind == .pie || p.plot.kind == .doughnut, p.series.count == 1 {
            let s = p.series[0]
            return p.categories.indices.filter { !hidden.contains($0) }.map { i in
                (p.categories[i], ns(s.series.pointColors[i] ?? theme.seriesColor(i)), false)
            }
        }
        var out: [(String, NSColor, Bool)] = []
        var i = 0
        for p in chart.plots {
            for s in p.series {
                defer { i += 1 }
                if hidden.contains(i) { continue }
                let isLine = p.plot.kind == .line || (p.plot.kind == .scatter && !s.series.noLine)
                out.append((s.name, isLine ? lineColor(s) : color(s), isLine))
            }
        }
        return out
    }

    /// Draws the legend at its position and returns the area left for the plot.
    private func drawLegend(_ legend: ChartLegend, in area: CGRect) -> CGRect {
        let entries = legendEntries
        let font = labelFont
        let sw = 9 * scale, gap = 5 * scale, pad = 12 * scale
        let rowH = max(size("国", font).height, sw) + 3 * scale
        func swatch(_ c: NSColor, _ line: Bool, at p: CGPoint) {
            c.setFill()
            if line {
                CGRect(x: p.x, y: p.y + sw / 2 - 1 * scale, width: sw * 1.6, height: 2 * scale).fill()
            } else {
                CGRect(x: p.x, y: p.y, width: sw, height: sw).fill()
            }
        }
        let vertical = legend.position == "r" || legend.position == "l" || legend.position == "tr"
        if vertical {
            let w = min(area.width * 0.35, (entries.map { size($0.0, font).width }.max() ?? 0) + sw * 1.6 + gap + pad)
            let totalH = CGFloat(entries.count) * rowH
            let x = legend.position == "l" ? area.minX : area.maxX - w
            var y = legend.position == "tr" ? area.minY : area.midY - min(totalH, area.height) / 2
            for e in entries where y + rowH <= area.maxY + 1 {
                swatch(e.1, e.2, at: CGPoint(x: x + pad / 2, y: y + (rowH - sw) / 2))
                let lx = x + pad / 2 + sw * 1.6 + gap
                drawText(e.0, font: font, color: labelColor, in: CGRect(x: lx, y: y + (rowH - size("国", font).height) / 2 - 1, width: max(1, x + w - lx), height: rowH), align: .left)
                y += rowH
            }
            if legend.overlay { return area }
            return legend.position == "l" ? CGRect(x: area.minX + w, y: area.minY, width: area.width - w, height: area.height)
                : CGRect(x: area.minX, y: area.minY, width: area.width - w, height: area.height)
        }
        // Top / bottom: entries flow in lines, centred.
        var lines: [[(String, NSColor, Bool, CGFloat)]] = [[]]
        var lineW: CGFloat = 0
        for e in entries {
            let w = sw * 1.6 + gap + size(e.0, font).width + pad
            if lineW + w > area.width && !(lines.last?.isEmpty ?? true) { lines.append([]); lineW = 0 }
            lines[lines.count - 1].append((e.0, e.1, e.2, w))
            lineW += w
        }
        let h = CGFloat(lines.count) * rowH + 4 * scale
        var y = legend.position == "t" ? area.minY : area.maxY - h + 2 * scale
        for line in lines {
            var x = area.midX - line.reduce(0) { $0 + $1.3 } / 2
            for e in line {
                swatch(e.1, e.2, at: CGPoint(x: x, y: y + (rowH - sw) / 2))
                label(e.0, at: CGPoint(x: x + sw * 1.6 + gap, y: y + rowH / 2), anchor: (0, 0.5))
                x += e.3
            }
            y += rowH
        }
        if legend.overlay { return area }
        return legend.position == "t" ? CGRect(x: area.minX, y: area.minY + h, width: area.width, height: area.height - h)
            : CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - h)
    }

    // MARK: Axes and scales

    struct Scale {
        var min: Double, max: Double, step: Double
        var ticks: [Double] {
            guard step > 0, max > min else { return [min] }
            var out: [Double] = []
            var v = min
            while v <= max + step * 1e-9 && out.count < 50 { out.append(abs(v) < step * 1e-9 ? 0 : v); v += step }
            return out
        }
        func pos(_ v: Double) -> Double { max > min ? (v - min) / (max - min) : 0 }
    }

    /// Round tick values covering the data, starting at zero when the data allows (as Excel does).
    static func niceScale(_ lo: Double, _ hi: Double, fixedMin: Double? = nil, fixedMax: Double? = nil, unit: Double? = nil, targetTicks: Int = 6) -> Scale {
        var a = fixedMin ?? min(lo, 0), b = fixedMax ?? max(hi, 0)
        if fixedMin == nil && lo > 0 && hi > 0 && (hi - lo) / hi < 0.16 { a = lo }   // all values close together: don't start at 0
        if a == b { b = a == 0 ? 1 : a + abs(a) * 0.5 }
        let raw = (b - a) / Double(max(2, targetTicks - 1))
        let mag = pow(10, floor(log10(raw)))
        let step = unit ?? ([1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? 10 * mag)
        let lo2 = fixedMin ?? (floor(a / step) * step)
        let hi2 = fixedMax ?? (ceil(b / step) * step)
        return Scale(min: lo2, max: hi2 == lo2 ? lo2 + step : hi2, step: step)
    }

    private func axis(_ id: String?) -> ChartAxis? { spec.axes.first { $0.id == id } }

    // MARK: Cartesian (bar, line, area, scatter, bubble)

    private struct Group {
        var plots: [ResolvedPlot]
        var axis: ChartAxis?
        var scale: Scale
        var secondary: Bool
        /// The first plot is a 100% stacked one: its axis reads in percent.
        var plot0Percent: Bool { plots.first?.plot.isPercent ?? false }
    }

    private func range(_ p: ResolvedPlot) -> (Double, Double) {
        if p.plot.isPercent { return (p.series.flatMap(\.values).contains { ($0 ?? 0) < 0 } ? -1 : 0, 1) }
        if p.plot.isStacked && (p.plot.kind == .bar || p.plot.kind == .area || p.plot.kind == .line) {
            var lo = 0.0, hi = 0.0
            let n = p.series.map(\.values.count).max() ?? 0
            for i in 0..<n {
                var pos = 0.0, neg = 0.0
                for s in p.series { let v = i < s.values.count ? (s.values[i] ?? 0) : 0; if v >= 0 { pos += v } else { neg += v } }
                hi = max(hi, pos); lo = min(lo, neg)
            }
            return (lo, hi)
        }
        let all = p.series.flatMap(\.values).compactMap { $0 }
        return (all.min() ?? 0, all.max() ?? 1)
    }

    private func drawCartesian(_ plots: [ResolvedPlot], in area: CGRect) {
        let horizontal = plots.contains { $0.plot.kind == .bar && $0.plot.horizontal }
        let xyPlots = plots.filter { $0.plot.kind == .scatter || $0.plot.kind == .bubble }
        let primaryCats = plots.first { $0.plot.kind != .scatter && $0.plot.kind != .bubble }?.categories ?? plots[0].categories
        let catCount = max(1, primaryCats.count)

        // Value axes: plots sharing a value axis share a scale; a second axis goes on the far side.
        var groups: [Group] = []
        for p in plots {
            let valID = p.plot.axisIDs.count > 1 ? p.plot.axisIDs[1] : nil
            if let i = groups.firstIndex(where: { $0.axis?.id == valID && valID != nil }) { groups[i].plots.append(p); continue }
            let ax = axis(valID)
            groups.append(Group(plots: [p], axis: ax, scale: Scale(min: 0, max: 1, step: 0.2), secondary: !groups.isEmpty))
        }
        for i in groups.indices {
            let lo = groups[i].plots.map { range($0).0 }.min() ?? 0, hi = groups[i].plots.map { range($0).1 }.max() ?? 1
            let a = groups[i].axis
            groups[i].scale = Self.niceScale(lo, hi, fixedMin: a?.min, fixedMax: a?.max, unit: a?.majorUnit,
                                             targetTicks: max(3, Int((horizontal ? area.width : area.height) / (40 * scale))))
        }
        // Scatter: x is a value axis too.
        var xScale: Scale?
        if !xyPlots.isEmpty {
            let xs = xyPlots.flatMap { $0.series }.flatMap { s in s.xValues ?? s.values.indices.map { Double($0 + 1) } }.compactMap { $0 }
            let ax = axis(xyPlots[0].plot.axisIDs.first)
            xScale = Self.niceScale(xs.min() ?? 0, xs.max() ?? 1, fixedMin: ax?.min, fixedMax: ax?.max, unit: ax?.majorUnit,
                                    targetTicks: max(3, Int(area.width / (70 * scale))))
        }

        let catAxis = axis(plots[0].plot.axisIDs.first)
        let font = labelFont
        let lineH = size("国", font).height
        func fmt(_ g: Group, _ v: Double) -> String {
            let code = (g.axis?.sourceLinked == false ? g.axis?.numberFormat : nil) ?? g.plots.first?.series.first?.numberFormat
            return format(v, g.plot0Percent ? "0%" : code)
        }
        // Room for tick labels.
        let primary = groups[0]
        let secondary = groups.count > 1 ? groups[1] : nil
        let valLabelW = { (g: Group?) -> CGFloat in
            guard let g, g.axis?.deleted != true, g.axis?.labelsShown != false else { return 0 }
            return (g.scale.ticks.map { size(fmt(g, $0), font).width }.max() ?? 0) + 6 * scale
        }
        let catLabels = primaryCats
        let catLabelW = (catLabels.map { size($0, font).width }.max() ?? 0) + 6 * scale
        let showCat = catAxis?.deleted != true && catAxis?.labelsShown != false
        var titleLeft: CGFloat = 0, titleBottom: CGFloat = 0
        let valTitle = primary.axis?.title.flatMap { $0.text }
        let catTitle = catAxis?.title.flatMap { $0.text }
        if valTitle != nil { if horizontal { titleBottom = lineH + 4 * scale } else { titleLeft = lineH + 4 * scale } }
        if catTitle != nil { if horizontal { titleLeft = lineH + 4 * scale } else { titleBottom = lineH + 4 * scale } }

        var plotRect: CGRect
        if horizontal {
            let left = (showCat ? min(catLabelW, area.width * 0.35) : 0) + titleLeft
            plotRect = CGRect(x: area.minX + left, y: area.minY + 4 * scale,
                              width: area.width - left - 8 * scale, height: area.height - lineH - 8 * scale - titleBottom)
        } else {
            let left = valLabelW(primary) + titleLeft
            let right = max(8 * scale, valLabelW(secondary))
            plotRect = CGRect(x: area.minX + left, y: area.minY + 6 * scale,
                              width: area.width - left - right, height: area.height - (showCat ? lineH + 6 * scale : 0) - 6 * scale - titleBottom)
        }
        guard plotRect.width > 10, plotRect.height > 10 else { return }
        if let bg = spec.plotBackground { ns(bg).setFill(); plotRect.fill() }

        // Positions.
        func valuePos(_ g: Group, _ v: Double) -> CGFloat {
            let t = CGFloat(g.scale.pos(v))
            let rev = g.axis?.reversed == true
            if horizontal { return rev ? plotRect.maxX - t * plotRect.width : plotRect.minX + t * plotRect.width }
            return rev ? plotRect.minY + t * plotRect.height : plotRect.maxY - t * plotRect.height
        }
        let slot = (horizontal ? plotRect.height : plotRect.width) / CGFloat(catCount)
        let catReversed = catAxis?.reversed == true
        func catStart(_ i: Int) -> CGFloat {
            // Horizontal bars: first category at the bottom, like Excel.
            if horizontal { return catReversed ? plotRect.minY + CGFloat(i) * slot : plotRect.maxY - CGFloat(i + 1) * slot }
            return catReversed ? plotRect.maxX - CGFloat(i + 1) * slot : plotRect.minX + CGFloat(i) * slot
        }
        let lineOnBetween = plots.contains { $0.plot.kind == .bar } || plots.contains { $0.plot.kind == .line }

        // Gridlines and value labels.
        for (gi, g) in groups.enumerated() where g.axis?.deleted != true || gi == 0 {
            if g.axis?.majorGridlines ?? (gi == 0) {
                NSColor(white: 0.88, alpha: 1).setFill()
                for t in g.scale.ticks {
                    let p = valuePos(g, t)
                    if horizontal { CGRect(x: p - 0.5, y: plotRect.minY, width: 1, height: plotRect.height).fill() }
                    else { CGRect(x: plotRect.minX, y: p - 0.5, width: plotRect.width, height: 1).fill() }
                }
            }
            guard g.axis?.deleted != true, g.axis?.labelsShown != false else { continue }
            for t in g.scale.ticks {
                let p = valuePos(g, t)
                if horizontal { label(fmt(g, t), at: CGPoint(x: p, y: plotRect.maxY + 3 * scale), anchor: (0.5, 0)) }
                else if gi == 0 { label(fmt(g, t), at: CGPoint(x: plotRect.minX - 4 * scale, y: p), anchor: (1, 0.5)) }
                else { label(fmt(g, t), at: CGPoint(x: plotRect.maxX + 4 * scale, y: p), anchor: (0, 0.5)) }
            }
        }
        if let xScale {
            // Gridlines first, labels after: drawing text changes the current fill colour.
            NSColor(white: 0.88, alpha: 1).setFill()
            let xs = xScale.ticks.map { plotRect.minX + CGFloat(xScale.pos($0)) * plotRect.width }
            for x in xs { CGRect(x: x - 0.5, y: plotRect.minY, width: 1, height: plotRect.height).fill() }
            for (t, x) in zip(xScale.ticks, xs) { label(format(t, nil), at: CGPoint(x: x, y: plotRect.maxY + 3 * scale), anchor: (0.5, 0)) }
        }
        // Category axis line and labels.
        NSColor(white: 0.75, alpha: 1).setFill()
        let zero = valuePos(primary, max(primary.scale.min, min(primary.scale.max, 0)))
        if horizontal { CGRect(x: zero - 0.5, y: plotRect.minY, width: 1, height: plotRect.height).fill() }
        else if xScale == nil || plots.count > xyPlots.count { CGRect(x: plotRect.minX, y: zero - 0.5, width: plotRect.width, height: 1).fill() }
        if showCat && plots.count > xyPlots.count {
            let every = horizontal ? max(1, Int(ceil(lineH / max(1, slot)))) : max(1, Int(ceil(catLabelW / max(1, slot))))
            for (i, c) in catLabels.enumerated() where i % every == 0 {
                let s0 = catStart(i)
                if horizontal {
                    let r = CGRect(x: area.minX + titleLeft, y: s0 + slot / 2 - lineH / 2, width: plotRect.minX - area.minX - titleLeft - 4 * scale, height: lineH)
                    drawText(c, font: font, color: labelColor, in: r, align: .right)
                } else {
                    let w = slot * CGFloat(every)
                    let r = CGRect(x: s0 + slot / 2 - w / 2, y: plotRect.maxY + 3 * scale, width: w, height: lineH * 2)
                    drawText(c, font: font, color: labelColor, in: r, align: .center)
                }
            }
        }
        // Axis titles.
        let titleFont = NSFont.systemFont(ofSize: px(9), weight: .medium)
        if let t = catTitle {
            if horizontal { verticalTitle(t, font: titleFont, x: area.minX, rect: plotRect) }
            else { label(t, at: CGPoint(x: plotRect.midX, y: area.maxY - lineH), anchor: (0.5, 0), font: titleFont) }
        }
        if let t = valTitle {
            if horizontal { label(t, at: CGPoint(x: plotRect.midX, y: area.maxY - lineH), anchor: (0.5, 0), font: titleFont) }
            else { verticalTitle(t, font: titleFont, x: area.minX, rect: plotRect) }
        }

        // Series. Bars of every bar plot are laid out together within each category.
        let barPlots = groups.flatMap { g in g.plots.filter { $0.plot.kind == .bar }.map { (g, $0) } }
        var barIndex = 0
        let barSlots = barPlots.reduce(0) { $0 + ($1.1.plot.isStacked ? 1 : $1.1.series.count) }
        for (g, p) in barPlots {
            drawBars(p, group: g, slots: barSlots, first: barIndex, slot: slot, horizontal: horizontal, catStart: catStart, valuePos: { valuePos(g, $0) })
            barIndex += p.plot.isStacked ? 1 : p.series.count
        }
        for g in groups {
            for p in g.plots where p.plot.kind == .area { drawArea(p, slot: slot, catStart: catStart, valuePos: { valuePos(g, $0) }) }
            for p in g.plots where p.plot.kind == .line {
                drawLines(p, slot: slot, onBetween: lineOnBetween, catStart: catStart, valuePos: { valuePos(g, $0) })
            }
            for p in g.plots where p.plot.kind == .scatter || p.plot.kind == .bubble {
                guard let xScale else { continue }
                drawScatter(p, plotRect: plotRect, x: { plotRect.minX + CGFloat(xScale.pos($0)) * plotRect.width }, y: { valuePos(g, $0) })
            }
        }
    }

    private func verticalTitle(_ t: String, font: NSFont, x: CGFloat, rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sz = size(t, font)
        ctx.saveGState()
        ctx.translateBy(x: x + sz.height / 2, y: rect.midY)
        ctx.rotate(by: -.pi / 2)
        (t as NSString).draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2), withAttributes: [.font: font, .foregroundColor: labelColor])
        ctx.restoreGState()
    }

    private func drawBars(_ p: ResolvedPlot, group: Group, slots: Int, first: Int, slot: CGFloat, horizontal: Bool,
                          catStart: (Int) -> CGFloat, valuePos: (Double) -> CGFloat) {
        let n = CGFloat(max(1, slots))
        let gap = CGFloat(p.plot.gapWidth) / 100
        let overlap = p.plot.isStacked ? 1 : CGFloat(p.plot.overlap) / 100
        let barW = slot / (n - (n - 1) * max(0, overlap) + gap)
        let step = barW * (1 - max(0, overlap))
        let clusterW = barW + step * (n - 1)
        let count = p.series.map(\.values.count).max() ?? 0
        let labels = p.plot.labels
        for i in 0..<count {
            var pos = 0.0, neg = 0.0
            let total = p.series.reduce(0.0) { $0 + abs(i < $1.values.count ? ($1.values[i] ?? 0) : 0) }
            for (k, s) in p.series.enumerated() {
                guard i < s.values.count, var v = s.values[i] else { continue }
                if p.plot.isPercent { v = total > 0 ? v / total : 0 }
                var base = 0.0
                if p.plot.isStacked { if v >= 0 { base = pos; pos += v } else { base = neg; neg += v } }
                let lane = CGFloat(first + (p.plot.isStacked ? 0 : k))
                let offset = catStart(i) + (slot - clusterW) / 2 + lane * step
                let a = valuePos(base), b = valuePos(base + v)
                let r = horizontal
                    ? CGRect(x: min(a, b), y: offset, width: abs(b - a), height: barW)
                    : CGRect(x: offset, y: min(a, b), width: barW, height: abs(b - a))
                let fill = s.series.pointColors[i].map(ns) ?? (p.plot.varyColors && p.series.count == 1 ? ns(theme.seriesColor(i)) : color(s))
                if !s.series.noFill { fill.setFill(); r.fill() }
                if let lc = s.series.line, !s.series.noLine {
                    ns(lc).setStroke()
                    let path = NSBezierPath(rect: r)
                    path.lineWidth = CGFloat(s.series.lineWidth ?? 0.75) * scale
                    path.stroke()
                }
                let l = s.series.labels ?? labels
                if l.value || l.seriesName || l.category {
                    var parts: [String] = []
                    if l.seriesName { parts.append(s.name) }
                    if l.category, i < p.categories.count { parts.append(p.categories[i]) }
                    if l.value { parts.append(format(s.values[i] ?? 0, l.numberFormat ?? s.numberFormat)) }
                    let text = parts.joined(separator: ", ")
                    if p.plot.isStacked { label(text, at: CGPoint(x: r.midX, y: r.midY), anchor: (0.5, 0.5)) }
                    else if horizontal { label(text, at: CGPoint(x: (v >= 0 ? r.maxX : r.minX) + (v >= 0 ? 3 : -3) * scale, y: r.midY), anchor: (v >= 0 ? 0 : 1, 0.5)) }
                    else { label(text, at: CGPoint(x: r.midX, y: v >= 0 ? r.minY - 2 * scale : r.maxY + 2 * scale), anchor: (0.5, v >= 0 ? 1 : 0)) }
                }
            }
        }
    }

    private func points(_ s: ResolvedSeries, slot: CGFloat, onBetween: Bool, catStart: (Int) -> CGFloat, y: (Double) -> CGFloat, values: [Double?]) -> [CGPoint?] {
        values.enumerated().map { i, v in
            guard let v else { return nil }
            let x = onBetween ? catStart(i) + slot / 2 : catStart(i)
            return CGPoint(x: x, y: y(v))
        }
    }

    private func stackedValues(_ p: ResolvedPlot) -> [[Double?]] {
        guard p.plot.isStacked else { return p.series.map(\.values) }
        let n = p.series.map(\.values.count).max() ?? 0
        var acc = [Double](repeating: 0, count: n)
        let totals = (0..<n).map { i in p.series.reduce(0.0) { $0 + abs(i < $1.values.count ? ($1.values[i] ?? 0) : 0) } }
        return p.series.map { s in
            (0..<n).map { i in
                var v = i < s.values.count ? (s.values[i] ?? 0) : 0
                if p.plot.isPercent { v = totals[i] > 0 ? v / totals[i] : 0 }
                acc[i] += v
                return acc[i]
            }
        }
    }

    private func stroke(_ pts: [CGPoint?], color: NSColor, width: CGFloat, dashed: Bool, smooth: Bool, spanGaps: Bool) {
        var runs: [[CGPoint]] = [[]]
        for p in pts {
            if let p { runs[runs.count - 1].append(p) } else if !spanGaps, !(runs.last?.isEmpty ?? true) { runs.append([]) }
        }
        color.setStroke()
        for run in runs where run.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            if dashed { path.setLineDash([4 * scale, 3 * scale], count: 2, phase: 0) }
            path.move(to: run[0])
            for i in 1..<run.count {
                if smooth {
                    let p0 = run[max(0, i - 2)], p1 = run[i - 1], p2 = run[i], p3 = run[min(run.count - 1, i + 1)]
                    let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                    let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                    path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
                } else {
                    path.line(to: run[i])
                }
            }
            path.stroke()
        }
    }

    private func marker(_ p: CGPoint, _ s: ResolvedSeries, color: NSColor) {
        let sym = s.series.marker ?? "circle"
        guard sym != "none" else { return }
        let r = CGFloat(s.series.markerSize ?? 5) * scale * 0.6
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        let path: NSBezierPath
        switch sym {
        case "square": path = NSBezierPath(rect: rect)
        case "diamond":
            path = NSBezierPath()
            path.move(to: CGPoint(x: p.x, y: rect.minY)); path.line(to: CGPoint(x: rect.maxX, y: p.y))
            path.line(to: CGPoint(x: p.x, y: rect.maxY)); path.line(to: CGPoint(x: rect.minX, y: p.y)); path.close()
        case "triangle":
            path = NSBezierPath()
            path.move(to: CGPoint(x: p.x, y: rect.minY)); path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY)); path.close()
        default: path = NSBezierPath(ovalIn: rect)
        }
        color.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 0.75 * scale
        path.stroke()
    }

    private func drawLines(_ p: ResolvedPlot, slot: CGFloat, onBetween: Bool, catStart: (Int) -> CGFloat, valuePos: (Double) -> CGFloat) {
        let stacked = stackedValues(p)
        for (k, s) in p.series.enumerated() {
            let vals: [Double?] = p.plot.isStacked ? stacked[k].enumerated().map { i, v in i < s.values.count && s.values[i] != nil ? v : nil } : s.values
            let pts = points(s, slot: slot, onBetween: onBetween, catStart: catStart, y: valuePos, values: vals)
            let c = lineColor(s)
            if !s.series.noLine {
                stroke(pts, color: c, width: CGFloat(s.series.lineWidth ?? 2.25) * scale, dashed: s.series.dashed, smooth: s.series.smooth,
                       spanGaps: spec.displayBlanksAs == "span")
            }
            if p.plot.markers { for case let q? in pts { marker(q, s, color: c) } }
            let l = s.series.labels ?? p.plot.labels
            if l.value {
                for (i, q) in pts.enumerated() { if let q, i < s.values.count, let v = s.values[i] { label(format(v, l.numberFormat ?? s.numberFormat), at: CGPoint(x: q.x, y: q.y - 5 * scale), anchor: (0.5, 1)) } }
            }
        }
    }

    private func drawArea(_ p: ResolvedPlot, slot: CGFloat, catStart: (Int) -> CGFloat, valuePos: (Double) -> CGFloat) {
        let stacked = stackedValues(p)
        // Stacked: from the top band down, so each lower band shows. Side by side: in order,
        // later series in front (as Excel draws them).
        for k in p.plot.isStacked ? Array(p.series.indices.reversed()) : Array(p.series.indices) {
            let s = p.series[k]
            let top = stacked[k]
            let below: [Double?] = p.plot.isStacked && k > 0 ? stacked[k - 1] : top.map { _ in 0 }
            let n = top.count
            guard n > 1 else { continue }
            let path = NSBezierPath()
            for i in 0..<n {
                let x = catStart(i) + slot / 2
                let pt = CGPoint(x: x, y: valuePos(top[i] ?? 0))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            for i in (0..<n).reversed() { path.line(to: CGPoint(x: catStart(i) + slot / 2, y: valuePos(below[i] ?? 0))) }
            path.close()
            color(s).withAlphaComponent(p.plot.isStacked ? 1 : 0.85).setFill()
            path.fill()
        }
    }

    private func drawScatter(_ p: ResolvedPlot, plotRect: CGRect, x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        let maxSize = p.series.flatMap { $0.sizes ?? [] }.compactMap { $0 }.max() ?? 1
        for s in p.series {
            let xs = s.xValues ?? s.values.indices.map { Double($0 + 1) }
            let pts: [CGPoint?] = s.values.enumerated().map { i, v in
                guard let v, i < xs.count, let xv = xs[i] else { return nil }
                return CGPoint(x: x(xv), y: y(v))
            }
            let c = lineColor(s)
            if p.plot.kind == .bubble {
                for (i, q) in pts.enumerated() {
                    guard let q else { continue }
                    let sz = (s.sizes.flatMap { i < $0.count ? $0[i] : nil } ?? 1) ?? 1
                    let r = max(3, sqrt(max(0, sz) / maxSize) * min(plotRect.width, plotRect.height) * 0.12)
                    color(s).withAlphaComponent(0.7).setFill()
                    NSBezierPath(ovalIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)).fill()
                }
                continue
            }
            if p.plot.scatterLines && !s.series.noLine {
                stroke(pts, color: c, width: CGFloat(s.series.lineWidth ?? 2) * scale, dashed: s.series.dashed, smooth: s.series.smooth, spanGaps: false)
            }
            if p.plot.markers || s.series.marker != nil { for case let q? in pts { marker(q, s, color: c) } }
        }
    }

    // MARK: Pie and doughnut

    private func drawPie(_ p: ResolvedPlot, in area: CGRect) {
        guard let s = p.series.first else { return drawEmpty(in: area) }
        let values = s.values.map { max(0, $0 ?? 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return drawEmpty(in: area) }
        let labels = s.series.labels ?? p.plot.labels
        let pad: CGFloat = labels.any ? 26 * scale : 6 * scale
        let radius = max(4, min(area.width, area.height) / 2 - pad)
        let c = CGPoint(x: area.midX, y: area.midY)
        let hole = p.plot.kind == .doughnut ? CGFloat(p.plot.holeSize) / 100 * radius : 0
        // Excel starts at 12 o'clock and goes clockwise; the view is flipped, so angles grow clockwise.
        var angle = -90 + p.plot.firstSliceAngle
        for (i, v) in values.enumerated() where v > 0 {
            let sweep = v / total * 360
            let path = NSBezierPath()
            if hole > 0 {
                path.appendArc(withCenter: c, radius: radius, startAngle: CGFloat(angle), endAngle: CGFloat(angle + sweep), clockwise: false)
                path.appendArc(withCenter: c, radius: hole, startAngle: CGFloat(angle + sweep), endAngle: CGFloat(angle), clockwise: true)
            } else {
                path.move(to: c)
                path.appendArc(withCenter: c, radius: radius, startAngle: CGFloat(angle), endAngle: CGFloat(angle + sweep), clockwise: false)
            }
            path.close()
            ns(s.series.pointColors[i] ?? theme.seriesColor(i)).setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = 1.2 * scale
            path.stroke()
            if labels.any {
                var parts: [String] = []
                if labels.category, i < p.categories.count { parts.append(p.categories[i]) }
                if labels.value { parts.append(format(v, labels.numberFormat ?? s.numberFormat)) }
                if labels.percent { parts.append(format(v / total, "0%")) }
                let mid = (angle + sweep / 2) * .pi / 180
                let rr = hole > 0 ? (radius + hole) / 2 : radius * 0.68
                label(parts.joined(separator: " "), at: CGPoint(x: c.x + CGFloat(cos(mid)) * rr, y: c.y + CGFloat(sin(mid)) * rr), anchor: (0.5, 0.5),
                      color: .white)
            }
            angle += sweep
        }
    }

    // MARK: Radar

    private func drawRadar(_ p: ResolvedPlot, in area: CGRect) {
        let n = p.categories.count
        guard n >= 3 else { return drawEmpty(in: area) }
        let all = p.series.flatMap(\.values).compactMap { $0 }
        let sc = Self.niceScale(min(0, all.min() ?? 0), all.max() ?? 1, targetTicks: 5)
        let labelH = size("国", labelFont).height
        let radius = max(4, min(area.width, area.height) / 2 - labelH * 2)
        let c = CGPoint(x: area.midX, y: area.midY)
        func point(_ i: Int, _ v: Double) -> CGPoint {
            let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * .pi
            let r = radius * CGFloat(sc.pos(v))
            return CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
        }
        NSColor(white: 0.85, alpha: 1).setStroke()
        for t in sc.ticks where t > sc.min {
            let ring = NSBezierPath()
            for i in 0..<n { let q = point(i, t); if i == 0 { ring.move(to: q) } else { ring.line(to: q) } }
            ring.close(); ring.lineWidth = 1; ring.stroke()
        }
        for i in 0..<n {
            // Set every time: the category label drawn below changes the current colours.
            NSColor(white: 0.85, alpha: 1).setStroke()
            let spoke = NSBezierPath(); spoke.move(to: c); spoke.line(to: point(i, sc.max)); spoke.lineWidth = 1; spoke.stroke()
            let q = point(i, sc.max)
            let dx = q.x - c.x, dy = q.y - c.y
            label(p.categories[i], at: CGPoint(x: q.x + dx * 0.08, y: q.y + dy * 0.08), anchor: (dx < -1 ? 1 : (dx > 1 ? 0 : 0.5), dy < -1 ? 1 : (dy > 1 ? 0 : 0.5)))
        }
        for s in p.series {
            let path = NSBezierPath()
            for i in 0..<n {
                let q = point(i, i < s.values.count ? (s.values[i] ?? 0) : 0)
                if i == 0 { path.move(to: q) } else { path.line(to: q) }
            }
            path.close()
            if p.plot.radarFilled { color(s).withAlphaComponent(0.45).setFill(); path.fill() }
            lineColor(s).setStroke()
            path.lineWidth = 2 * scale
            path.stroke()
        }
    }
}
