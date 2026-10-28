import Foundation

/// Writes Markdown as a real Word document (WordprocessingML): built-in heading styles (they show
/// in Word's navigation pane), bordered tables with a shaded header row, bullet and numbered
/// lists, quotes, code, emphasis and links. Opens in Word, WPS, Pages and Loupe.
public enum DocxWriter {
    public static func write(markdown: String, title: String, to dest: URL) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-docx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func put(_ path: String, _ s: String) throws {
            let f = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try s.write(to: f, atomically: true, encoding: .utf8)
        }
        var links: [String] = []
        let (body, numberedLists) = document(MarkdownParser.blocks(markdown), links: &links)
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try put("[Content_Types].xml", head + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """)
        try put("_rels/.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """)
        let linkRels = links.enumerated().map { i, u in
            "<Relationship Id=\"rLink\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(XMLEscape.text(u))\" TargetMode=\"External\"/>"
        }.joined()
        try put("word/_rels/document.xml.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\(linkRels)</Relationships>
        """)
        let now = ISO8601DateFormatter().string(from: Date())
        try put("docProps/core.xml", head + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(XMLEscape.text(title))</dc:title><dc:creator>Loupe AI</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created></cp:coreProperties>
        """)
        try put("word/styles.xml", head + styles)
        try put("word/numbering.xml", head + numbering(lists: numberedLists))
        try put("word/document.xml", head + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1304" w:bottom="1440" w:left="1304" w:header="851" w:footer="992" w:gutter="0"/></w:sectPr></w:body></w:document>
        """)
        let tmp = AtomicWrite.tempNear(dest, ext: "docx")
        try Zip.pack(directory: work, to: tmp)
        try AtomicWrite.replace(dest, with: tmp)
    }

    // MARK: Body

    /// The body XML, and how many numbered lists it has (each restarts at 1).
    static func document(_ blocks: [MarkdownBlock], links: inout [String]) -> (String, Int) {
        var out = ""
        var numberedLists = 0
        for b in blocks {
            switch b {
            case .heading(let level, let text):
                out += para(text, style: "Heading\(min(level, 4))", links: &links)
            case .paragraph(let lines):
                // Lines inside one paragraph are soft line breaks.
                out += "<w:p>" + lines.enumerated().map { i, l in (i > 0 ? "<w:r><w:br/></w:r>" : "") + runs(l, links: &links) }.joined() + "</w:p>"
            case .list(let ordered, let items):
                var numID = 1
                if ordered { numberedLists += 1; numID = 1 + numberedLists }
                for it in items {
                    out += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numID)\"/></w:numPr></w:pPr>\(runs(it, links: &links))</w:p>"
                }
            case .table(let header, let rows):
                out += table(header, rows, links: &links)
            case .quote(let lines):
                for l in lines { out += para(l, style: "Quote", links: &links) }
            case .code(let text):
                for l in text.components(separatedBy: "\n") {
                    out += "<w:p><w:pPr><w:pStyle w:val=\"Code\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(XMLEscape.text(l))</w:t></w:r></w:p>"
                }
            case .rule:
                out += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BBBBBB\"/></w:pBdr></w:pPr></w:p>"
            }
        }
        return (out, numberedLists)
    }

    static func para(_ text: String, style: String, links: inout [String]) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(runs(text, links: &links))</w:p>"
    }

    static func runs(_ text: String, links: inout [String]) -> String {
        MarkdownParser.runs(text).map { r -> String in
            var props = ""
            if r.bold { props += "<w:b/><w:bCs/>" }
            if r.italic { props += "<w:i/><w:iCs/>" }
            if r.strike { props += "<w:strike/>" }
            if r.code { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F0EC\"/>" }
            if r.link != nil { props += "<w:color w:val=\"2F4FA8\"/><w:u w:val=\"single\"/>" }
            let run = "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>") + "<w:t xml:space=\"preserve\">\(XMLEscape.text(r.text))</w:t></w:r>"
            if let u = r.link {
                links.append(u)
                return "<w:hyperlink r:id=\"rLink\(links.count)\">\(run)</w:hyperlink>"
            }
            return run
        }.joined()
    }

    static func table(_ header: [String], _ rows: [[String]], links: inout [String]) -> String {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        guard cols > 0 else { return "" }
        let widths = columnWidths(header, rows, cols: cols, total: 9298)
        let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\""
        // Borders and widths are written on the table itself, not only in its style: some
        // renderers (Quick Look, older WPS) ignore table styles.
        var t = "<w:tbl><w:tblPr><w:tblStyle w:val=\"LoupeTable\"/><w:tblW w:w=\"9298\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/>"
        t += "<w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/><w:insideH \(border)/><w:insideV \(border)/></w:tblBorders>"
        t += "<w:tblCellMar><w:top w:w=\"40\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:bottom w:w=\"40\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
        t += widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        func row(_ cells: [String], header: Bool) -> String {
            var r = "<w:tr>" + (header ? "<w:trPr><w:tblHeader/><w:cantSplit/></w:trPr>" : "<w:trPr><w:cantSplit/></w:trPr>")
            for c in 0..<cols {
                let text = c < cells.count ? cells[c] : ""
                r += "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[c])\" w:type=\"dxa\"/>"
                r += "<w:tcBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/></w:tcBorders>"
                r += (header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F0EEE9\"/>" : "") + "</w:tcPr>"
                // <br> inside a cell becomes a new line.
                let parts = text.replacingOccurrences(of: "<br/>", with: "<br>").replacingOccurrences(of: "<br />", with: "<br>").components(separatedBy: "<br>")
                for p in parts {
                    let content = header ? "**\(MarkdownParser.plain(p))**" : p
                    r += "<w:p><w:pPr><w:pStyle w:val=\"TableText\"/></w:pPr>\(runs(content, links: &links))</w:p>"
                }
                r += "</w:tc>"
            }
            return r + "</w:tr>"
        }
        t += row(header, header: true)
        for r in rows { t += row(r, header: false) }
        // A table must be followed by a paragraph in Word.
        return t + "</w:tbl><w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>"
    }

    /// Column widths in proportion to how much text each column holds: a 序号 column stays
    /// narrow, an explanation column gets the room. Every column keeps a readable minimum.
    static func columnWidths(_ header: [String], _ rows: [[String]], cols: Int, total: Int) -> [Int] {
        func weight(_ s: String) -> Double {
            MarkdownParser.plain(s).reduce(0.0) { $0 + ($1.isASCII ? 0.55 : 1) }
        }
        var w = (0..<cols).map { c -> Double in
            let cells = rows.map { c < $0.count ? weight($0[c]) : 0 }
            let avg = cells.isEmpty ? 0 : cells.reduce(0, +) / Double(cells.count)
            let longest = cells.max() ?? 0
            return max(weight(c < header.count ? header[c] : ""), min(longest, avg * 1.6), 2)
        }
        let sum = w.reduce(0, +)
        w = w.map { $0 / sum }
        let minimum = min(0.08, 1 / Double(cols))
        // Raise narrow columns to the minimum, taking the room from the wide ones.
        let short = w.filter { $0 < minimum }.reduce(0) { $0 + (minimum - $1) }
        let wideTotal = w.filter { $0 >= minimum }.reduce(0, +)
        w = w.map { $0 < minimum ? minimum : $0 - short * ($0 / max(wideTotal, 0.0001)) }
        return w.map { Int(($0 * Double(total)).rounded()) }
    }

    // MARK: Parts

    static let fonts = "<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"PingFang SC\" w:cs=\"Arial\"/>"

    static let styles = """
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults><w:rPrDefault><w:rPr>\(fonts)<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="200"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="120"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="25"/><w:szCs w:val="25"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="60"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="23"/><w:szCs w:val="23"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="60"/><w:ind w:left="420" w:hanging="300"/></w:pPr></w:style>
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="D9481C"/></w:pBdr><w:ind w:left="240"/></w:pPr><w:rPr><w:color w:val="555555"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F5F3EF"/><w:spacing w:after="0" w:line="260" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="18"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="TableText"><w:name w:val="Table Text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="40" w:after="40" w:line="280" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
    <w:style w:type="table" w:styleId="LoupeTable"><w:name w:val="Loupe Table"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:color="999999"/><w:left w:val="single" w:sz="4" w:color="999999"/><w:bottom w:val="single" w:sz="4" w:color="999999"/><w:right w:val="single" w:sz="4" w:color="999999"/><w:insideH w:val="single" w:sz="4" w:color="999999"/><w:insideV w:val="single" w:sz="4" w:color="999999"/></w:tblBorders><w:tblCellMar><w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
    </w:styles>
    """

    /// numId 1: bullets; numId 2…: numbered lists, each restarting at 1.
    static func numbering(lists: Int) -> String {
        var s = "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        s += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"singleLevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"420\" w:hanging=\"300\"/></w:pPr></w:lvl></w:abstractNum>"
        s += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"singleLevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"420\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
        s += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for i in 0..<max(1, lists) {
            s += "<w:num w:numId=\"\(i + 2)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        return s + "</w:numbering>"
    }
}
