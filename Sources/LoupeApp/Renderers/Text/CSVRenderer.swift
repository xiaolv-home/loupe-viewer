import AppKit
import SwiftUI
import LoupeCore

/// Native table for CSV/TSV. Parsing streams in 1 MB chunks on a background task;
/// the table appears after the first batch and grows while the rest loads.
@MainActor
final class CSVRenderer: NSObject, Renderer, ObservableObject, NSTableViewDataSource, NSTableViewDelegate {
    static let engineName = "CSV"
    nonisolated static let maxRows = 2_000_000
    static func canHandle(_ file: FileContext) -> Bool { !file.isDirectory }

    @Published var headerFirst = true { didSet { rebuildColumns(); table.reloadData() } }
    @Published var progress: Double = 0
    private var rows: [[String]] = []
    private var columnCount = 0
    private var truncated = false
    private var encodingName = ""
    private var delimiter: UInt8 = 44
    private let table = NSTableView()
    private var loadTask: Task<Void, Never>?
    private weak var host: RenderHost?
    private let font = NSFont.systemFont(ofSize: 12)
    private let numFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        let wide = TextEncodingDetector.detect(file.head)
        if wide.unitWidth > 1 && file.size > SpreadsheetReader.wideTextLimit {
            throw RenderError.unreadable("UTF-16/32 表格超过 32MB，已停止载入以免占满内存")
        }
        delimiter = file.format.delimiter ?? (file.ext == "tsv" || file.ext == "tab" ? 9 : (CSVSniffer.sniffDelimiter(TextSniffer.leadingText(file.head, max: 16 * 1024)) ?? 44))
        let url = file.url
        let delim = delimiter
        let size = max(file.size, 1)

        table.style = .plain
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = Theme.hairline
        table.backgroundColor = Theme.codeBackground
        table.usesAlternatingRowBackgroundColors = false
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = Theme.codeBackground

        // Stream rows in. The first batch is awaited so the table never shows empty.
        let (stream, cont) = AsyncStream<([[String]], Double, String, Bool)>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            CSVRenderer.parse(url: url, delimiter: delim, size: size, cont: cont)
        }
        var first = true
        var iterator = stream.makeAsyncIterator()
        host.reportProgress(0, label: "正在解析表格…")
        while first, let (batch, frac, enc, done) = await iterator.next() {
            if Task.isCancelled { worker.cancel(); throw RenderError.cancelled }
            append(batch, frac: frac, enc: enc)
            if rows.count >= 200 || done { first = false }
            if done { progress = 1 }
        }
        host.reportProgress(nil, label: nil)
        if rows.isEmpty { worker.cancel(); throw RenderError.unreadable("表格为空或无法解析") }
        rebuildColumns()
        table.reloadData()

        loadTask = Task { [weak self] in
            while let (batch, frac, enc, done) = await iterator.next() {
                guard let self, !Task.isCancelled else { worker.cancel(); return }
                self.append(batch, frac: frac, enc: enc)
                if done { self.progress = 1 }
                self.table.noteNumberOfRowsChanged()
                self.host?.rendererDidUpdate()
            }
        }
        return scroll
    }

    private func append(_ batch: [[String]], frac: Double, enc: String) {
        encodingName = enc
        progress = frac
        let room = Self.maxRows - rows.count
        if batch.count > room { truncated = true }
        rows.append(contentsOf: batch.prefix(max(0, room)))
        let widest = batch.reduce(0) { max($0, $1.count) }
        if widest > columnCount {
            let had = columnCount
            columnCount = widest
            if had > 0 { rebuildColumns() }
        }
    }

    nonisolated static func parse(url: URL, delimiter: UInt8, size: Int64,
                                  cont: AsyncStream<([[String]], Double, String, Bool)>.Continuation) {
        defer { cont.finish() }
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        let enc = TextEncodingDetector.detect(head)
        var parser: CSVParser
        var pending = Data()
        var consumed: Int64 = 0
        if enc.unitWidth > 1 {
            if size > SpreadsheetReader.wideTextLimit { return }
            // UTF-16/32: transcode the whole file to UTF-8 first (rare for CSV).
            try? h.seek(toOffset: 0)
            let all = (try? h.readToEnd()) ?? Data()
            pending = Data(TextEncodingDetector.decode(all, as: enc).utf8)
            parser = CSVParser(delimiter: delimiter, encoding: .utf8)
        } else {
            pending = enc.bomLength > 0 ? head.dropFirst(enc.bomLength) : head
            parser = CSVParser(delimiter: delimiter, encoding: enc.encoding == .utf8 ? .utf8 : enc.encoding)
        }
        var batch: [[String]] = []
        var lastFlush = Date()
        var rowsSent = 0
        while true {
            if Task.isCancelled { return }
            if !pending.isEmpty {
                consumed += Int64(pending.count)
                let rows = parser.feed(pending)
                batch.append(contentsOf: rows)
                pending = Data()
            }
            if batch.count >= 5000 || Date().timeIntervalSince(lastFlush) > 0.2 || (rowsSent == 0 && batch.count >= 200) {
                rowsSent += batch.count
                cont.yield((batch, min(1, Double(consumed) / Double(size)), enc.name, false))
                batch = []
                lastFlush = Date()
                if rowsSent >= maxRows { return }
            }
            guard enc.unitWidth == 1, let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            pending = chunk
        }
        if let last = parser.finish() { batch.append(last) }
        cont.yield((batch, 1, enc.name, true))
    }

    private func rebuildColumns() {
        for c in table.tableColumns { table.removeTableColumn(c) }
        let num = NSTableColumn(identifier: .init("#"))
        num.title = ""
        num.width = CGFloat(max(3, String(rows.count).count)) * 7 + 16
        num.minWidth = 30
        table.addTableColumn(num)
        let header = headerFirst ? (rows.first ?? []) : []
        let sample = rows.dropFirst(headerFirst ? 1 : 0).prefix(300)
        for i in 0..<columnCount {
            let c = NSTableColumn(identifier: .init("\(i)"))
            let title = i < header.count && !header[i].isEmpty ? header[i] : Self.columnLetter(i)
            c.title = title
            c.headerCell.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            c.headerToolTip = title
            // Width from content sample: average of the longest few cells, clamped.
            var w = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
            for r in sample where i < r.count {
                let cw = (r[i].prefix(80) as NSString).size(withAttributes: [.font: font]).width
                if cw > w { w = cw }
            }
            c.width = min(360, max(56, w + 20))
            c.minWidth = 36
            table.addTableColumn(c)
        }
    }

    static func columnLetter(_ i: Int) -> String {
        var n = i, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    private var dataRows: Int { max(0, rows.count - (headerFirst ? 1 : 0)) }

    func numberOfRows(in tableView: NSTableView) -> Int { dataRows }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let id = col?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(t)
            v.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 7),
                t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -7),
                t.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            return v
        }()
        guard let t = cell.textField else { return cell }
        if id.rawValue == "#" {
            t.font = numFont
            t.textColor = Theme.gutterText
            t.alignment = .right
            t.stringValue = "\(row + 1)"
            return cell
        }
        let r = row + (headerFirst ? 1 : 0)
        let ci = Int(id.rawValue) ?? 0
        let v = r < rows.count && ci < rows[r].count ? rows[r][ci] : ""
        t.font = font
        let numeric = Double(v.replacingOccurrences(of: ",", with: "")) != nil
        t.alignment = numeric ? .right : .left
        t.textColor = numeric ? Theme.syntax(.number) : .labelColor
        t.stringValue = v.replacingOccurrences(of: "\n", with: " ⏎ ")
        t.toolTip = v.count > 40 ? v : nil
        return cell
    }

    func cleanup() {
        loadTask?.cancel()
        table.dataSource = nil
        table.delegate = nil
        rows = []
    }

    var statusText: String {
        var s = "\(Fmt.number(dataRows)) 行 × \(columnCount) 列 · \(delimiter == 9 ? "制表符分隔" : (delimiter == 59 ? "分号分隔" : "逗号分隔"))"
        if progress < 1 { s += " · 加载中 \(Int(progress * 100))%" }
        if truncated { s += " · 仅显示前 \(Fmt.number(Self.maxRows)) 行" }
        return s
    }
    var infoSections: [InfoSection] {
        [InfoSection("表格", [InfoItem("行数", Fmt.number(dataRows) + (progress < 1 ? "（加载中）" : "")),
                              InfoItem("列数", "\(columnCount)"), InfoItem("编码", encodingName)])]
    }
    var controls: AnyView? { AnyView(CSVControls(r: self)) }
    var initialFirstResponder: NSView? { table }

    @objc func copy(_ sender: Any?) {
        let lines = table.selectedRowIndexes.map { i -> String in
            let r = i + (headerFirst ? 1 : 0)
            return r < rows.count ? rows[r].joined(separator: "\t") : ""
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct CSVControls: View {
    @ObservedObject var r: CSVRenderer
    var body: some View {
        Toggle("首行为表头", isOn: $r.headerFirst)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
    }
}
