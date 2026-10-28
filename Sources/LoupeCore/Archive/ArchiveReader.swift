import Foundation
import CArchive

public struct ArchiveEntry: Sendable {
    public var path: String
    public var size: Int64?
    public var modified: Date?
    public var isDirectory: Bool
    public var isEncrypted: Bool
    public var isSymlink: Bool
}

public struct ArchiveListing: Sendable {
    public var entries: [ArchiveEntry]
    public var formatName: String
    public var filterName: String
    public var truncated: Bool
    public var errorMessage: String?
}

public enum ArchiveError: Error, LocalizedError {
    case openFailed(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "无法读取压缩包：\(m)"
        case .cancelled: return "已取消"
        }
    }
}

/// Thin wrapper over the system libarchive. Lists entries without extracting.
public enum ArchiveReader {
    public static let maxEntries = 200_000

    public static func list(url: URL, progress: ((Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) throws -> ArchiveListing {
        guard let a = archive_read_new() else { throw ArchiveError.openFailed("libarchive 初始化失败") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        // A lone .gz/.bz2/.xz is not an archive format; "raw" exposes it as a single entry.
        archive_read_support_format_raw(a)
        guard archive_read_open_filename(a, url.path, 64 * 1024) == LA_ARCHIVE_OK else {
            throw ArchiveError.openFailed(errorString(a))
        }
        var entries: [ArchiveEntry] = []
        var entry: OpaquePointer?
        var truncated = false
        var err: String?
        while true {
            if isCancelled() { throw ArchiveError.cancelled }
            let r = archive_read_next_header(a, &entry)
            if r == LA_ARCHIVE_EOF { break }
            if r == LA_ARCHIVE_WARN { /* keep going */ }
            else if r != LA_ARCHIVE_OK {
                err = errorString(a)
                break
            }
            guard let e = entry else { break }
            let path = decodePath(e)
            let type = archive_entry_filetype(e) & 0o170000
            let size: Int64? = archive_entry_size_is_set(e) != 0 ? archive_entry_size(e) : nil
            let mtime = archive_entry_mtime(e)
            entries.append(ArchiveEntry(
                path: path, size: size,
                modified: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil,
                isDirectory: type == 0o040000 || path.hasSuffix("/"),
                isEncrypted: archive_entry_is_encrypted(e) != 0,
                isSymlink: type == 0o120000))
            if entries.count % 500 == 0 { progress?(entries.count) }
            if entries.count >= maxEntries { truncated = true; break }
            // Skipping data still decompresses streams (tar.gz); acceptable and cancellable per entry.
            if archive_read_data_skip(a) != LA_ARCHIVE_OK {
                // Encrypted or damaged data: listing can still continue for most formats.
            }
        }
        var filters: [String] = []
        let fc = archive_filter_count(a)
        if fc > 0 {
            for i in 0..<fc { if let n = archive_filter_name(a, i) { let s = String(cString: n); if s != "none" { filters.append(s) } } }
        }
        let fmt = archive_format_name(a).map { String(cString: $0) } ?? "未知"
        if entries.isEmpty, let err { throw ArchiveError.openFailed(err) }
        return ArchiveListing(entries: entries, formatName: fmt, filterName: filters.joined(separator: " + "),
                              truncated: truncated, errorMessage: err)
    }

    /// Extracts a single small entry (e.g. iWork preview.jpg) into memory.
    public static func extract(url: URL, matching predicate: (String) -> Bool, maxBytes: Int = 64 << 20) -> (String, Data)? {
        guard let a = archive_read_new() else { return nil }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, url.path, 64 * 1024) == LA_ARCHIVE_OK else { return nil }
        var entry: OpaquePointer?
        while archive_read_next_header(a, &entry) == LA_ARCHIVE_OK, let e = entry {
            let path = decodePath(e)
            guard predicate(path) else { archive_read_data_skip(a); continue }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                out.append(buf, count: n)
                if out.count > maxBytes { return nil }
            }
            return (path, out)
        }
        return nil
    }

    /// The first `bytes` of one entry (enough to read a header without inflating the rest).
    public static func extractHead(url: URL, matching predicate: (String) -> Bool, bytes: Int) -> Data? {
        guard let a = archive_read_new() else { return nil }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, url.path, 64 * 1024) == LA_ARCHIVE_OK else { return nil }
        var entry: OpaquePointer?
        while archive_read_next_header(a, &entry) == LA_ARCHIVE_OK, let e = entry {
            guard predicate(decodePath(e)) else { archive_read_data_skip(a); continue }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            while out.count < bytes {
                let n = buf.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            return out
        }
        return nil
    }

    /// Extracts every entry accepted by `predicate` in one pass (e.g. the XML parts of an .xlsx).
    public static func extractAll(url: URL, matching predicate: (String) -> Bool, maxBytes: Int = 512 << 20) throws -> [String: Data] {
        guard let a = archive_read_new() else { throw ArchiveError.openFailed("libarchive 初始化失败") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, url.path, 64 * 1024) == LA_ARCHIVE_OK else { throw ArchiveError.openFailed(errorString(a)) }
        var out: [String: Data] = [:]
        var total = 0
        var entry: OpaquePointer?
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while archive_read_next_header(a, &entry) == LA_ARCHIVE_OK, let e = entry {
            let path = decodePath(e)
            guard predicate(path) else { archive_read_data_skip(a); continue }
            var d = Data()
            while true {
                let n = buf.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                if n < 0 { throw ArchiveError.openFailed(errorString(a)) }
                if n == 0 { break }
                d.append(buf, count: n)
                total += n
                if total > maxBytes { throw ArchiveError.openFailed("内容过大") }
            }
            out[path] = d
        }
        return out
    }

    static func errorString(_ a: OpaquePointer) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "未知错误"
    }

    /// Prefer libarchive's UTF-8 conversion; fall back to our own detection for GBK-named zips.
    static func decodePath(_ e: OpaquePointer) -> String {
        if let raw = archive_entry_pathname(e) {
            let len = strlen(raw)
            let data = Data(bytes: raw, count: len)
            if TextEncodingDetector.isValidUTF8(data, allowTruncatedTail: false) {
                return String(decoding: data, as: UTF8.self)
            }
            if let s = String(data: data, encoding: DetectedEncoding.gb18030.encoding) { return s }
        }
        if let u = archive_entry_pathname_utf8(e) { return String(cString: u) }
        return "（无法解码的文件名）"
    }
}
