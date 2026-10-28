import AppKit
import LoupeCore

/// Where the AI may read and write, and how its files are written.
@MainActor
enum AIFiles {
    static let fileCreated = Notification.Name("LoupeAIFileCreated")
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }

    /// A path the model wrote: absolute, ~/…, or relative to `base`.
    static func resolve(_ path: String, base: URL) -> URL {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("~") { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL }
        if p.hasPrefix("/") { return URL(fileURLWithPath: p).standardizedFileURL }
        return base.appendingPathComponent(p).standardizedFileURL
    }

    /// The folder relative paths are taken from: the open document's, else the sidebar's, else 文稿.
    static func baseFolder(near file: URL?, browsing: URL? = nil) -> URL {
        if let f = file { return f.deletingLastPathComponent() }
        if let b = browsing { return b }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? home
    }

    /// Never hand the model credentials or app data: dot-folders in the home folder (.ssh, .aws…)
    /// and ~/Library are off limits, except Loupe's own skills.
    static func readable(_ url: URL) -> String? {
        let p = url.standardizedFileURL.path
        if p.hasPrefix(AISkills.installedRoot.path) || p.hasPrefix(AISkills.builtInRoot.path) { return nil }
        let h = home.path + "/"
        if p.hasPrefix(h) {
            let rel = String(p.dropFirst(h.count))
            if rel.hasPrefix(".") || rel.hasPrefix("Library/") || rel == "Library" { return "出于安全，不读取 ~/\(rel.split(separator: "/").first ?? "") 里的内容（可能含密码或应用数据）" }
        }
        if p.hasPrefix("/System/") || p.hasPrefix("/private/etc") || p.hasPrefix("/etc/") { return "不读取系统文件" }
        return nil
    }

    /// Writes stay inside the home folder (outside ~/Library and dot-folders) or /tmp.
    static func writable(_ url: URL) -> String? {
        let p = url.standardizedFileURL.path
        if p.hasPrefix("/private/tmp/") || p.hasPrefix("/tmp/") { return nil }
        let h = home.path + "/"
        guard p.hasPrefix(h) else { return "只能写到你的个人文件夹里" }
        let rel = String(p.dropFirst(h.count))
        if rel.hasPrefix(".") || rel.hasPrefix("Library/") || rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            return "不写入隐藏文件夹或 ~/Library"
        }
        return nil
    }

    /// A free name next to `url` ("报告 2.docx") when it is taken.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for i in 2...999 {
            let u = dir.appendingPathComponent("\(stem) \(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return url
    }

    /// Writes sheets as .xlsx or .csv (never over an existing file: a free name is chosen).
    static func writeTable(_ sheets: [(name: String, rows: [[CellValue]])], to path: String, near file: URL?) -> Result<URL, AIError> {
        var url = resolve(path, base: baseFolder(near: file))
        if url.pathExtension.isEmpty { url.appendPathExtension("xlsx") }
        if let why = writable(url) { return .failure(AIError(why)) }
        url = unique(url)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch url.pathExtension.lowercased() {
            case "csv":
                _ = try CSVWriter.write(rows: sheets.first?.rows ?? [], format: CSVFormat(delimiter: 44, encoding: .utf8, bom: true, crlf: true), to: url)
            case "tsv":
                _ = try CSVWriter.write(rows: sheets.first?.rows ?? [], format: CSVFormat(delimiter: 9, encoding: .utf8, bom: true, crlf: true), to: url)
            case "xlsx":
                // Text starting with "=" is written as a live formula, with its value worked out
                // now so the file shows numbers even in viewers that do not recalculate.
                var wb = Workbook(sheets: sheets.map { s in
                    var sh = Sheet(name: s.name, rows: s.rows)
                    sh.columnCount = s.rows.reduce(0) { max($0, $1.count) }
                    for (r, row) in s.rows.enumerated() {
                        for (c, v) in row.enumerated() {
                            if case .text(let t) = v, t.hasPrefix("="), t.count > 1 { sh.formulas[Sheet.key(r, c)] = t; sh.rows[r][c] = .empty }
                        }
                    }
                    return sh
                }, source: "")
                for i in wb.sheets.indices {
                    for key in wb.sheets[i].formulas.keys.sorted() {
                        let f = wb.sheets[i].formulas[key]!
                        let v = FormulaEngine.evaluate(f, in: FormulaContext(workbook: wb, sheet: i))
                        wb.sheets[i].rows[key / 16384][key % 16384] = v.cell
                    }
                }
                try XLSXWriter.write(sheets: wb.sheets.map { (name: $0.name, rows: $0.rows, formulas: $0.formulas) }, to: url)
            default:
                return .failure(AIError("表格只能存成 .xlsx、.csv 或 .tsv"))
            }
            return .success(url)
        } catch {
            return .failure(AIError("写入失败：\(error.localizedDescription)"))
        }
    }

    /// Tells the AI panel a file was produced (it shows Open / Show in Finder).
    static func announce(_ url: URL) {
        NotificationCenter.default.post(name: fileCreated, object: url)
    }
}
