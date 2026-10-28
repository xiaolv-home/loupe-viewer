import AppKit
import LoupeCore

/// Draws the objects of a drawing (charts, pictures, shapes, text boxes) into rectangles of a
/// flipped view. Shared by every renderer that shows Office drawings.
@MainActor
final class DrawingPainter {
    /// Decoded pictures and resolved charts, so scrolling does not redo the work.
    private var images: [Int: NSImage] = [:]
    private var charts: [Int: ResolvedChart] = [:]

    func reset() { images = [:]; charts = [:] }

    /// - Parameters:
    ///   - key: identifies the item across paints (for the caches).
    ///   - resolve: turns a chart spec into data (from the workbook it sits in).
    func draw(_ item: DrawingItem, key: Int, in rect: CGRect, scale: CGFloat, resolve: (ChartSpec) -> ResolvedChart) {
        guard rect.width >= 1, rect.height >= 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        if item.rotation != 0 || item.flipH || item.flipV {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            if item.rotation != 0 { ctx.rotate(by: CGFloat(item.rotation) * .pi / 180) }
            ctx.scaleBy(x: item.flipH ? -1 : 1, y: item.flipV ? -1 : 1)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        switch item.content {
        case .chart(let spec):
            let resolved: ResolvedChart
            if let c = charts[key] { resolved = c } else { resolved = resolve(spec); charts[key] = resolved }
            ChartPainter(chart: resolved, scale: scale).draw(in: rect)
        case .picture(let pic):
            if images[key] == nil { images[key] = NSImage(data: pic.data) ?? NSImage() }
            if let img = images[key], img.isValid, img.size.width > 0 {
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else {
                placeholder("图片（无法解码）", in: rect, scale: scale)
            }
        case .shape(let shape):
            drawShape(shape, in: rect, scale: scale)
        case .placeholder(let what):
            placeholder(what, in: rect, scale: scale)
        }
        ctx.restoreGState()
    }

    // MARK: Shapes

    private func ns(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    private func path(_ geometry: String, _ r: CGRect) -> NSBezierPath {
        let m = min(r.width, r.height)
        switch geometry {
        case "ellipse", "oval", "circle": return NSBezierPath(ovalIn: r)
        case "roundRect", "flowChartAlternateProcess", "wedgeRoundRectCallout":
            return NSBezierPath(roundedRect: r, xRadius: m * 0.16, yRadius: m * 0.16)
        case "triangle", "isoscelesTriangle", "flowChartExtract":
            return polygon([(0.5, 0), (1, 1), (0, 1)], r)
        case "rtTriangle": return polygon([(0, 0), (1, 1), (0, 1)], r)
        case "diamond", "flowChartDecision": return polygon([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)], r)
        case "parallelogram", "flowChartInputOutput": return polygon([(0.25, 0), (1, 0), (0.75, 1), (0, 1)], r)
        case "trapezoid": return polygon([(0.25, 0), (0.75, 0), (1, 1), (0, 1)], r)
        case "pentagon", "homePlate": return polygon([(0, 0), (0.8, 0), (1, 0.5), (0.8, 1), (0, 1)], r)
        case "chevron": return polygon([(0, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0, 1), (0.25, 0.5)], r)
        case "hexagon": return polygon([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)], r)
        case "octagon": return polygon([(0.3, 0), (0.7, 0), (1, 0.3), (1, 0.7), (0.7, 1), (0.3, 1), (0, 0.7), (0, 0.3)], r)
        case "rightArrow": return polygon([(0, 0.25), (0.65, 0.25), (0.65, 0), (1, 0.5), (0.65, 1), (0.65, 0.75), (0, 0.75)], r)
        case "leftArrow": return polygon([(1, 0.25), (0.35, 0.25), (0.35, 0), (0, 0.5), (0.35, 1), (0.35, 0.75), (1, 0.75)], r)
        case "upArrow": return polygon([(0.25, 1), (0.25, 0.35), (0, 0.35), (0.5, 0), (1, 0.35), (0.75, 0.35), (0.75, 1)], r)
        case "downArrow": return polygon([(0.25, 0), (0.25, 0.65), (0, 0.65), (0.5, 1), (1, 0.65), (0.75, 0.65), (0.75, 0)], r)
        case "star5":
            var pts: [(Double, Double)] = []
            for i in 0..<10 {
                let a = -Double.pi / 2 + Double(i) * .pi / 5, rr = i % 2 == 0 ? 0.5 : 0.2
                pts.append((0.5 + cos(a) * rr, 0.5 + sin(a) * rr))
            }
            return polygon(pts, r)
        case "flowChartTerminator": return NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        default:
            return NSBezierPath(rect: r)
        }
    }

    private func polygon(_ pts: [(Double, Double)], _ r: CGRect) -> NSBezierPath {
        let p = NSBezierPath()
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: r.minX + CGFloat(q.0) * r.width, y: r.minY + CGFloat(q.1) * r.height)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        return p
    }

    private func drawShape(_ s: DrawingShape, in r: CGRect, scale: CGFloat) {
        let line = s.line
        let lineColor = line?.color.map(ns) ?? NSColor(white: 0.35, alpha: 1)
        let lineWidth = max(0.5, CGFloat(line?.width ?? 0.75) * 4 / 3 * scale)
        if s.isLine {
            guard line?.none != true else { return }
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.maxY))
            p.lineWidth = lineWidth
            if line?.dashed == true { p.setLineDash([4 * scale, 3 * scale], count: 2, phase: 0) }
            lineColor.setStroke()
            p.stroke()
            lineColor.setFill()
            if line?.tailArrow == true { arrowHead(at: CGPoint(x: r.maxX, y: r.maxY), from: CGPoint(x: r.minX, y: r.minY), size: lineWidth * 4) }
            if line?.headArrow == true { arrowHead(at: CGPoint(x: r.minX, y: r.minY), from: CGPoint(x: r.maxX, y: r.maxY), size: lineWidth * 4) }
            return
        }
        let shape = path(s.geometry, r.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        if let f = s.fill, !s.noFill { ns(f).setFill(); shape.fill() }
        if line?.none != true, s.line != nil || (s.fill != nil && !s.noFill) {
            lineColor.setStroke()
            shape.lineWidth = lineWidth
            if line?.dashed == true { shape.setLineDash([4 * scale, 3 * scale], count: 2, phase: 0) }
            shape.stroke()
        }
        drawText(s, in: r.insetBy(dx: 7 * scale, dy: 4 * scale), scale: scale)
    }

    private func arrowHead(at tip: CGPoint, from tail: CGPoint, size: CGFloat) {
        let a = atan2(tip.y - tail.y, tip.x - tail.x)
        let p = NSBezierPath()
        p.move(to: tip)
        p.line(to: CGPoint(x: tip.x - cos(a - 0.45) * size, y: tip.y - sin(a - 0.45) * size))
        p.line(to: CGPoint(x: tip.x - cos(a + 0.45) * size, y: tip.y - sin(a + 0.45) * size))
        p.close()
        p.fill()
    }

    private func drawText(_ s: DrawingShape, in r: CGRect, scale: CGFloat) {
        guard s.paragraphs.contains(where: { !$0.text.isEmpty }), r.width > 2, r.height > 2 else { return }
        let text = NSMutableAttributedString()
        for (i, p) in s.paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.alignment = p.alignment == "ctr" ? .center : p.alignment == "r" ? .right : p.alignment == "just" ? .justified : .left
            for run in p.runs {
                let size = CGFloat(run.size ?? 11) * 4 / 3 * scale
                var font = NSFont.systemFont(ofSize: size, weight: run.bold ? .semibold : .regular)
                if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style,
                                                            .foregroundColor: run.color.map(ns) ?? NSColor(white: 0.12, alpha: 1)]
                if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                text.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            if i < s.paragraphs.count - 1 { text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
        }
        let h = ceil(text.boundingRect(with: CGSize(width: r.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
        var y = r.minY
        if s.verticalAnchor == "ctr" { y = r.midY - min(h, r.height) / 2 }
        if s.verticalAnchor == "b" { y = r.maxY - min(h, r.height) }
        text.draw(with: CGRect(x: r.minX, y: y, width: r.width, height: min(h, r.height)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// An object Loupe cannot draw: a labelled box where it sits, so nothing looks missing.
    private func placeholder(_ what: String, in r: CGRect, scale: CGFloat) {
        NSColor(white: 0.96, alpha: 1).setFill()
        r.fill()
        NSColor(white: 0.8, alpha: 1).setStroke()
        let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        p.setLineDash([4, 3], count: 2, phase: 0)
        p.stroke()
        let f = NSFont.systemFont(ofSize: 12 * scale)
        let s = what as NSString
        let size = s.size(withAttributes: [.font: f])
        s.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: [.font: f, .foregroundColor: NSColor(white: 0.45, alpha: 1)])
    }
}
