import Foundation

/// Scratch folders for tests, all under one folder that the next run clears first,
/// so test runs never pile up temp files.
enum TestTemp {
    static let root: URL = {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-tests")
        try? FileManager.default.removeItem(at: r)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }()

    static func dir(_ name: String) -> URL {
        let d = root.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
