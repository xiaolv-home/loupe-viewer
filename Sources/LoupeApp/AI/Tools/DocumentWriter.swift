import AppKit
import LoupeCore

/// Writes what the AI produced as a real file: Markdown becomes a formatted Word document, PDF,
/// web page or RTF; anything else is written as text (UTF-8).
@MainActor
enum DocumentWriter {
    static let richExtensions: Set<String> = ["docx", "pdf", "rtf", "html", "htm", "doc", "odt"]

    static func write(markdown content: String, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "html", "htm":
            try Data(MarkdownHTML.document(content, title: title).utf8).write(to: url, options: .atomic)
        case "docx":
            try DocxWriter.write(markdown: content, title: title, to: url)
        case "doc", "odt", "rtf":
            let s = try attributed(content, title: title)
            let type: NSAttributedString.DocumentType
            switch ext {
            case "doc": type = .docFormat
            case "odt": type = .openDocument
            default: type = .rtf
            }
            let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: type, .title: title])
            try data.write(to: url, options: .atomic)
        case "pdf":
            try pdf(attributed(content, title: title), to: url)
        default:
            try Data(content.utf8).write(to: url, options: .atomic)
        }
    }

    static func attributed(_ markdown: String, title: String) throws -> NSAttributedString {
        let html = MarkdownHTML.document(markdown, title: title)
        guard let s = NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                         documentAttributes: nil) else {
            throw AIError("排版失败")
        }
        return s
    }

    /// A4 pages with 2 cm margins.
    static func pdf(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        let margin: CGFloat = 57
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - 2 * margin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 100
        view.frame.size.height = max(used, 100)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw AIError("生成 PDF 失败") }
    }
}
