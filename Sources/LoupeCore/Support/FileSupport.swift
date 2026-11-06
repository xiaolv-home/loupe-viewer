import Foundation

enum XMLEscape {
    static func text(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 forbids most control characters.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

enum Zip {
    /// Zips a directory into an .xlsx-style package ([Content_Types].xml first).
    static func pack(directory: URL, to out: URL) throws {
        try? FileManager.default.removeItem(at: out)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = directory
            p.arguments = args
            p.standardOutput = Pipe()
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 && p.terminationStatus != 12 {  // 12 = nothing to do
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw SaveError("压缩失败：\(msg)")
            }
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("[Content_Types].xml").path) {
            try run(["-X", "-q", "-D", out.path, "[Content_Types].xml"])
        }
        try run(["-X", "-q", "-r", "-D", out.path, ".", "-x", "[Content_Types].xml", "-x", ".DS_Store"])
    }
}

/// Writes a file next to its destination first, then swaps it in, so a failure never
/// leaves a half-written document behind.
enum AtomicWrite {
    static func replace(_ dest: URL, with temp: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: dest)
        }
        // The system's "item replacement" folder stays behind empty otherwise.
        let holder = temp.deletingLastPathComponent()
        if holder != fm.temporaryDirectory, (try? fm.contentsOfDirectory(atPath: holder.path))?.isEmpty == true {
            try? fm.removeItem(at: holder)
        }
    }

    static func tempNear(_ dest: URL, ext: String) -> URL {
        let dir =
            (try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("loupe-\(UUID().uuidString).\(ext)")
    }
}

public struct SaveError: Error, LocalizedError {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}
