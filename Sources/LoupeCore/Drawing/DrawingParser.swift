import Foundation

/// Reads a SpreadsheetML drawing part (`xl/drawings/drawingN.xml`) with the parts it points
/// to (charts, pictures) into SheetDrawings.
public enum DrawingParser {
    /// - Parameters:
    ///   - path: the drawing part's own path, for resolving its relationships.
    ///   - part: reads another part of the package by path.
    public static func parse(_ data: Data, path: String, theme: DrawingTheme, part: (String) -> Data?) -> [SheetDrawing] {
        guard let root = XMLTree.parse(data) else { return [] }
        let rels = OfficeRels.parse(part(OfficeRels.relsPath(for: path)), base: path)
        var out: [SheetDrawing] = []
        for a in root.children {
            guard let anchor = anchor(a) else { continue }
            var items: [DrawingItem] = []
            for node in a.children { items += objects(node, rels: rels, theme: theme, part: part, frame: .full) }
            if !items.isEmpty { out.append(SheetDrawing(anchor: anchor, items: items)) }
        }
        return out
    }

    static func anchor(_ a: XMLTree) -> DrawingAnchor? {
        func marker(_ m: XMLTree?) -> DrawingAnchor.Marker? {
            guard let m, let col = m.child("col").flatMap({ Int($0.text) }), let row = m.child("row").flatMap({ Int($0.text) }) else { return nil }
            let colOff = m.child("colOff").flatMap { Double($0.text) } ?? 0
            let rowOff = m.child("rowOff").flatMap { Double($0.text) } ?? 0
            return DrawingAnchor.Marker(row: row, col: col, rowOffset: rowOff / DrawingAnchor.emuPerPixel, colOffset: colOff / DrawingAnchor.emuPerPixel)
        }
        var out = DrawingAnchor()
        switch a.name {
        case "twoCellAnchor":
            out.from = marker(a.child("from"))
            out.to = marker(a.child("to"))
            guard out.from != nil, out.to != nil else { return nil }
        case "oneCellAnchor":
            out.from = marker(a.child("from"))
            guard out.from != nil else { return nil }
        case "absoluteAnchor":
            let pos = a.child("pos")
            out.x = pos?["x"].flatMap(Double.init).map { $0 / DrawingAnchor.emuPerPixel } ?? 0
            out.y = pos?["y"].flatMap(Double.init).map { $0 / DrawingAnchor.emuPerPixel } ?? 0
        default:
            return nil
        }
        if let ext = a.child("ext") {
            out.width = ext["cx"].flatMap(Double.init).map { $0 / DrawingAnchor.emuPerPixel }
            out.height = ext["cy"].flatMap(Double.init).map { $0 / DrawingAnchor.emuPerPixel }
        }
        // A zero size (chart sheets: "fit the window") is no size at all.
        if out.width == 0 || out.height == 0 { out.width = nil; out.height = nil }
        if out.to == nil && (out.width == nil || out.height == nil) {
            // No size given: fall back to the object's own transform (or a default chart size).
            let xfrm = a.firstDescendant("xfrm")?.child("ext")
            let w = xfrm?["cx"].flatMap(Double.init).map { $0 / DrawingAnchor.emuPerPixel } ?? 0
            let h = xfrm?["cy"].flatMap(Double.init).map { $0 / DrawingAnchor.emuPerPixel } ?? 0
            let page = a.name == "absoluteAnchor"
            out.width = w > 0 ? w : (page ? 960 : 480)
            out.height = h > 0 ? h : (page ? 600 : 288)
        }
        return out
    }

    static func objects(_ node: XMLTree, rels: [String: String], theme: DrawingTheme, part: (String) -> Data?, frame: UnitRect) -> [DrawingItem] {
        switch node.name {
        case "AlternateContent":
            // Newer content with a fallback for older readers: take the first branch that
            // gives something drawable.
            for branch in node.children("Choice") + node.children("Fallback") {
                let items = branch.children.flatMap { objects($0, rels: rels, theme: theme, part: part, frame: frame) }
                if items.contains(where: { if case .placeholder = $0.content { return false }; return true }) { return items }
            }
            return node.children("Choice").first.map { $0.children.flatMap { objects($0, rels: rels, theme: theme, part: part, frame: frame) } } ?? []
        case "grpSp":
            let x = node.at("grpSpPr", "xfrm")
            let off = point(x?.child("off")), ext = point(x?.child("ext"), x: "cx", y: "cy")
            let chOff = point(x?.child("chOff")) ?? off, chExt = point(x?.child("chExt"), x: "cx", y: "cy") ?? ext
            var items: [DrawingItem] = []
            for c in node.children where c.name != "nvGrpSpPr" && c.name != "grpSpPr" {
                var childFrame = UnitRect.full
                if let cx = c.firstDescendant("xfrm"), let co = point(cx.child("off")), let ce = point(cx.child("ext"), x: "cx", y: "cy"),
                   let chOff, let chExt, chExt.0 > 0, chExt.1 > 0 {
                    childFrame = UnitRect(x: (co.0 - chOff.0) / chExt.0, y: (co.1 - chOff.1) / chExt.1, width: ce.0 / chExt.0, height: ce.1 / chExt.1)
                }
                items += objects(c, rels: rels, theme: theme, part: part, frame: childFrame.within(frame))
            }
            return items
        case "sp", "cxnSp":
            var item = DrawingItem(content: .shape(shape(node, theme: theme)))
            transform(node, into: &item, frame: frame)
            return [item]
        case "pic":
            guard let embed = node.firstDescendant("blip")?["embed"], let target = rels[embed], let data = part(target) else {
                return [placed(.placeholder("图片"), node, frame)]
            }
            let name = node.firstDescendant("cNvPr")?["name"] ?? (target as NSString).lastPathComponent
            return [placed(.picture(DrawingPicture(data: data, name: name)), node, frame)]
        case "graphicFrame":
            guard let gd = node.firstDescendant("graphicData") else { return [] }
            let uri = gd["uri"] ?? ""
            if uri.hasSuffix("/chart"), let id = gd.child("chart")?["id"], let target = rels[id], let data = part(target) {
                let chartTheme = theme
                if let spec = ChartParser.parse(data, theme: chartTheme) { return [placed(.chart(spec), node, frame)] }
                return [placed(.placeholder("图表"), node, frame)]
            }
            if uri.contains("chartex") { return [placed(.placeholder("新式图表（瀑布图 / 树状图等）"), node, frame)] }
            if uri.contains("diagram") { return [placed(.placeholder("SmartArt 图形"), node, frame)] }
            return [placed(.placeholder("嵌入对象"), node, frame)]
        case "contentPart":
            return [DrawingItem(content: .placeholder("墨迹"))]
        default:
            return []
        }
    }

    private static func placed(_ content: DrawingContent, _ node: XMLTree, _ frame: UnitRect) -> DrawingItem {
        var item = DrawingItem(content: content)
        transform(node, into: &item, frame: frame)
        return item
    }

    private static func transform(_ node: XMLTree, into item: inout DrawingItem, frame: UnitRect) {
        item.frame = frame
        let x = node.child("spPr")?.child("xfrm") ?? node.child("xfrm") ?? node.child("grpSpPr")?.child("xfrm")
        if let x {
            item.rotation = (x["rot"].flatMap(Double.init) ?? 0) / 60000
            item.flipH = x["flipH"].map(ChartParser.flag) ?? false
            item.flipV = x["flipV"].map(ChartParser.flag) ?? false
        }
    }

    private static func point(_ n: XMLTree?, x: String = "x", y: String = "y") -> (Double, Double)? {
        guard let n, let a = n[x].flatMap(Double.init), let b = n[y].flatMap(Double.init) else { return nil }
        return (a, b)
    }

    static func shape(_ node: XMLTree, theme: DrawingTheme) -> DrawingShape {
        var s = DrawingShape()
        let spPr = node.child("spPr")
        s.isLine = node.name == "cxnSp"
        if let g = spPr?.child("prstGeom")?["prst"] { s.geometry = g }
        if ["line", "straightConnector1", "bentConnector2", "bentConnector3", "curvedConnector3"].contains(s.geometry) { s.isLine = true }
        // The shape's style refers to theme colours used when spPr says nothing.
        let style = node.child("style")
        let styleFill = style?.child("fillRef").flatMap { ref in (ref["idx"] ?? "0") == "0" ? nil : DrawingStyle.color(in: ref, theme: theme) }
        let styleLine = style?.child("lnRef").flatMap { ref in (ref["idx"] ?? "0") == "0" ? nil : DrawingStyle.color(in: ref, theme: theme) }
        let styleFont = style?.child("fontRef").flatMap { DrawingStyle.color(in: $0, theme: theme) }
        switch DrawingStyle.fill(in: spPr, theme: theme, placeholder: styleFill) {
        case .solid(let c)?: s.fill = c
        case .none?: s.noFill = true
        case nil: s.fill = s.isLine ? nil : styleFill
        }
        var line = DrawingStyle.line(in: spPr, theme: theme, placeholder: styleLine) ?? DrawingLine()
        if line.color == nil && !line.none { line.color = styleLine }
        if line.color != nil || line.none || line.width != nil || line.dashed || line.headArrow || line.tailArrow { s.line = line }
        if let body = node.child("txBody") {
            let bodyPr = body.child("bodyPr")
            s.verticalAnchor = bodyPr?["anchor"] ?? "t"
            s.vertical = (bodyPr?["vert"] ?? "horz").hasPrefix("vert") && bodyPr?["vert"] != "horz"
            let defaults = body.child("lstStyle")?.firstDescendant("defRPr")
            for p in body.children("p") {
                var para = DrawingParagraph()
                para.alignment = p.child("pPr")?["algn"] ?? "l"
                for r in p.children {
                    switch r.name {
                    case "r", "fld":
                        var run = DrawingRun(text: r.child("t")?.text ?? "")
                        let rPr = r.child("rPr") ?? p.child("pPr")?.child("defRPr") ?? defaults
                        run.size = rPr?["sz"].flatMap(Double.init).map { $0 / 100 }
                        run.bold = rPr?["b"].map(ChartParser.flag) ?? false
                        run.italic = rPr?["i"].map(ChartParser.flag) ?? false
                        run.underline = (rPr?["u"] ?? "none") != "none"
                        run.color = DrawingStyle.color(in: rPr?.child("solidFill"), theme: theme) ?? styleFont
                        para.runs.append(run)
                    case "br":
                        para.runs.append(DrawingRun(text: "\n"))
                    default: break
                    }
                }
                s.paragraphs.append(para)
            }
            // Trailing empty paragraphs only add height.
            while let last = s.paragraphs.last, last.text.isEmpty, s.paragraphs.count > 1 { s.paragraphs.removeLast() }
        }
        return s
    }
}

/// Relationships of a package part (`_rels/x.xml.rels`), with targets resolved to full paths.
public enum OfficeRels {
    public static func relsPath(for path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return (dir.isEmpty ? "" : dir + "/") + "_rels/" + (path as NSString).lastPathComponent + ".rels"
    }

    public static func parse(_ data: Data?, base: String) -> [String: String] {
        guard let data, let root = XMLTree.parse(data) else { return [:] }
        var out: [String: String] = [:]
        for r in root.children("Relationship") {
            guard let id = r["Id"], let target = r["Target"], r["TargetMode"] != "External" else { continue }
            out[id] = resolve(target, from: base)
        }
        return out
    }

    /// `../charts/chart1.xml` seen from `xl/drawings/drawing1.xml` → `xl/charts/chart1.xml`.
    public static func resolve(_ target: String, from base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = (base as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for p in target.split(separator: "/") {
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }
}
