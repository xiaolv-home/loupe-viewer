import Foundation

/// Markdown → HTML for the documents the AI writes as web pages and PDFs.
public enum MarkdownHTML {
    public static func render(_ md: String) -> String {
        MarkdownParser.blocks(md).map { b -> String in
            switch b {
            case .heading(let level, let text): return "<h\(level)>\(inline(text))</h\(level)>"
            case .paragraph(let lines): return "<p>" + lines.map(inline).joined(separator: "<br>") + "</p>"
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                return "<\(tag)>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</\(tag)>"
            case .table(let header, let rows):
                var t = "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                for r in rows { t += "<tr>" + r.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
                return t + "</tbody></table>"
            case .quote(let lines): return "<blockquote><p>" + lines.map(inline).joined(separator: "<br>") + "</p></blockquote>"
            case .code(let text): return "<pre><code>" + escape(text) + "</code></pre>"
            case .rule: return "<hr>"
            }
        }.joined(separator: "\n")
    }

    /// A complete page with print-friendly styles.
    public static func document(_ md: String, title: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font-family: "PingFang SC", -apple-system, sans-serif; font-size: 11pt; line-height: 1.6; color: #1e1d1b; margin: 0; }
        h1 { font-size: 20pt; margin: 0 0 10pt; } h2 { font-size: 15pt; margin: 16pt 0 6pt; } h3 { font-size: 12.5pt; margin: 12pt 0 4pt; }
        p { margin: 0 0 8pt; } ul, ol { margin: 0 0 8pt 18pt; padding: 0; } li { margin: 2pt 0; }
        table { border-collapse: collapse; width: 100%; margin: 6pt 0 10pt; page-break-inside: auto; }
        tr { page-break-inside: avoid; }
        th, td { border: 0.6pt solid #999; padding: 4pt 6pt; text-align: left; vertical-align: top; font-size: 10pt; }
        th { background: #f0eee9; }
        blockquote { margin: 0 0 8pt; padding-left: 10pt; border-left: 2pt solid #d9481c; color: #555; }
        pre { background: #f5f3ef; padding: 8pt; font-size: 9.5pt; white-space: pre-wrap; }
        code { font-family: Menlo, monospace; font-size: 9.5pt; }
        hr { border: 0; border-top: 0.6pt solid #bbb; margin: 12pt 0; }
        @page { size: A4; margin: 20mm; }
        </style></head><body>
        \(render(md))
        </body></html>
        """
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        // A model's <br> inside table cells stays a line break.
        let parts = s.replacingOccurrences(of: "<br/>", with: "<br>").replacingOccurrences(of: "<br />", with: "<br>").components(separatedBy: "<br>")
        return parts.map { part in
            MarkdownParser.runs(part).map { r -> String in
                var t = escape(r.text)
                if r.code { t = "<code>\(t)</code>" }
                if r.bold { t = "<strong>\(t)</strong>" }
                if r.italic { t = "<em>\(t)</em>" }
                if r.strike { t = "<del>\(t)</del>" }
                if let u = r.link { t = "<a href=\"\(escape(u).replacingOccurrences(of: "\"", with: "&quot;"))\">\(t)</a>" }
                return t
            }.joined()
        }.joined(separator: "<br>")
    }
}
