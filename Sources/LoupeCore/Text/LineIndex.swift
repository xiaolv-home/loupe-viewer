import Foundation

/// Memory-mapped line index for very large text files. Lines are decoded lazily,
/// so a multi-gigabyte log opens instantly and scrolls smoothly.
public final class LineIndex: @unchecked Sendable {
    public let data: Data
    public let encoding: DetectedEncoding
    /// Byte offset of the start of each line.
    public private(set) var starts: [Int] = []
    private let lock = NSLock()
    public private(set) var isComplete = false

    public init(url: URL) throws {
        self.data = try Data(contentsOf: url, options: [.alwaysMapped])
        self.encoding = TextEncodingDetector.detect(data.prefix(256 * 1024))
        starts = [encoding.bomLength]
    }

    public init(data: Data) {
        self.data = data
        self.encoding = TextEncodingDetector.detect(data.prefix(256 * 1024))
        starts = [encoding.bomLength]
    }

    public var lineCount: Int { lock.lock(); defer { lock.unlock() }; return starts.count }

    /// Scans the whole file for newlines, reporting progress (0…1). Cancellable through `isCancelled`.
    public func build(progress: ((Double, Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) {
        let total = data.count
        let unit = encoding.unitWidth
        let be = encoding.bigEndian
        var local: [Int] = []
        local.reserveCapacity(1 << 16)
        let chunk = 8 << 20
        var offset = encoding.bomLength
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while offset < total {
                if isCancelled() { return }
                let end = min(total, offset + chunk)
                if unit == 1 {
                    var p = offset
                    while p < end {
                        guard let hit = memchr(base + p, 0x0A, end - p) else { break }
                        let idx = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                        if idx + 1 < total { local.append(idx + 1) }
                        p = idx + 1
                    }
                } else {
                    var p = offset - (offset - encoding.bomLength) % unit
                    while p + unit <= end {
                        let isNL: Bool
                        if unit == 2 {
                            isNL = be ? (base[p] == 0 && base[p + 1] == 0x0A) : (base[p] == 0x0A && base[p + 1] == 0)
                        } else {
                            isNL = be ? (base[p + 3] == 0x0A && base[p] == 0 && base[p + 1] == 0 && base[p + 2] == 0)
                                      : (base[p] == 0x0A && base[p + 1] == 0 && base[p + 2] == 0 && base[p + 3] == 0)
                        }
                        if isNL && p + unit < total { local.append(p + unit) }
                        p += unit
                    }
                }
                offset = end
                lock.lock(); starts.append(contentsOf: local); lock.unlock()
                local.removeAll(keepingCapacity: true)
                progress?(Double(offset) / Double(max(total, 1)), lineCount)
            }
        }
        lock.lock(); isComplete = true; lock.unlock()
        progress?(1, lineCount)
    }

    public func byteRange(ofLine i: Int) -> Range<Int>? {
        lock.lock(); defer { lock.unlock() }
        guard i >= 0 && i < starts.count else { return nil }
        let s = starts[i]
        let e = i + 1 < starts.count ? starts[i + 1] : (isComplete ? data.count : min(data.count, s + 64 * 1024))
        return s..<max(s, e)
    }

    /// Decoded line without trailing newline. Overly long lines are clipped for display.
    public func line(_ i: Int, maxBytes: Int = 16 * 1024) -> String {
        guard let r = byteRange(ofLine: i) else { return "" }
        var range = r
        var clipped = false
        if range.count > maxBytes {
            let cut = range.lowerBound + maxBytes - (maxBytes % encoding.unitWidth)
            range = range.lowerBound..<cut
            clipped = true
        }
        var s = TextEncodingDetector.decode(data.subdata(in: range), as: DetectedEncoding(encoding.encoding, encoding.name, bom: 0, unit: encoding.unitWidth, bigEndian: encoding.bigEndian))
        while let last = s.unicodeScalars.last, last == "\n" || last == "\r" { s.unicodeScalars.removeLast() }
        if clipped { s += " …" }
        return s
    }
}
