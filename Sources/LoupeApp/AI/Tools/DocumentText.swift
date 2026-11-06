import AppKit
import PDFKit
import Vision
import LoupeCore

/// Turns any file the AI is pointed at into text it can read: plain text in its own encoding,
/// PDF pages, Word/RTF/ODT, PowerPoint slides, tables, and images (recognised with Vision).
enum DocumentText {
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "html", "htm", "log",
                                              "ini", "toml", "conf", "swift", "py", "js", "ts", "java", "go", "rs", "c", "h", "cpp", "sql",
                                              "sh", "rb", "php", "css", "srt", "vtt", "tex", "rst", "org"]

    @MainActor static func extract(_ url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { throw AIError("这是文件夹，请用 list_folder") }
        switch ext {
        case "pdf":
            return try await Task.detached(priority: .userInitiated) { try pdf(url) }.value
        case "docx", "doc", "rtf", "rtfd", "odt", "wordml", "webarchive":
            return try attributed(url)
        case "pptx":
            return try await Task.detached(priority: .userInitiated) { try slides(url) }.value
        case "xlsx", "xlsm", "ods", "xls":
            return try await Task.detached(priority: .userInitiated) { try table(url) }.value
        case "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp":
            return try await Task.detached(priority: .userInitiated) { try ocr(url) }.value
        case "pages", "key", "numbers":
            throw AIError("Pages / Keynote / Numbers 文件请先在对应的应用里导出成 Word、PPT 或 Excel")
        default:
            if (values?.fileSize ?? 0) > 50 << 20 { throw AIError("文件太大（超过 50 MB），不适合整篇读取") }
            let head = FormatDetector.readHead(url, length: 4096)
            guard textExtensions.contains(ext) || TextSniffer.isLikelyText(head) else {
                throw AIError("这个文件不是文字内容（\(ext.isEmpty ? "二进制" : ext)），读不出来")
            }
            return try TextFileFormat.read(url).0
        }
    }

    nonisolated static func pdf(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw AIError("PDF 打不开（可能已损坏或加密）") }
        if doc.isLocked { throw AIError("PDF 有密码，读不了") }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            let t = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            parts.append("--- 第 \(i + 1) 页 ---\n" + t)
        }
        let all = parts.joined(separator: "\n\n")
        if all.replacingOccurrences(of: "--- 第", with: "").filter({ !$0.isWhitespace }).count < doc.pageCount * 10 {
            return all + "\n\n（这个 PDF 几乎没有文字层，可能是扫描件。）"
        }
        return all
    }

    @MainActor static func attributed(_ url: URL) throws -> String {
        let s = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        return s.string
    }

    nonisolated static func slides(_ url: URL) throws -> String {
        let parts = try ArchiveReader.extractAll(url: url) { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        func number(_ p: String) -> Int { Int(p.filter(\.isNumber)) ?? 0 }
        let re = try NSRegularExpression(pattern: "<a:t>([^<]*)</a:t>")
        return parts.keys.sorted { number($0) < number($1) }.map { key in
            let xml = String(decoding: parts[key]!, as: UTF8.self)
            let texts = re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
                Range($0.range(at: 1), in: xml).map { unescapeXML(String(xml[$0])) }
            }
            return "--- 第 \(number(key)) 页幻灯片 ---\n" + texts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    nonisolated static func table(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let wb: Workbook
        switch ext {
        case "ods": wb = try SpreadsheetReader.readODS(url: url)
        case "xls": throw AIError("旧版 .xls 请先在 Loupe 里打开（会自动转换）再让我读当前表格")
        default: wb = try SpreadsheetReader.readXLSX(url: url)
        }
        return wb.sheets.map { s in
            "--- 工作表「\(s.name)」（\(s.rows.count) 行 × \(s.columnCount) 列）---\n" + SheetSummary.tsv(s.rows, limit: 300)
        }.joined(separator: "\n\n")
    }

    nonisolated static func ocr(_ url: URL) throws -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw AIError("图片打不开")
        }
        return try ocr(img)
    }

    nonisolated static func ocr(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: img).perform([req])
        let pieces = (req.results ?? []).compactMap { o -> OCRLayout.Piece? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            return OCRLayout.Piece(text: t, box: o.boundingBox)
        }
        if pieces.isEmpty { return "（图片里没有识别到文字。尺寸 \(img.width)×\(img.height)。）" }
        return "（以下是从图片中识别出的文字，同一行的内容用制表符隔开）\n" + OCRLayout.rows(pieces)
    }

    nonisolated static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
