import Foundation
import CoreGraphics

/// Puts text recognised in an image back into lines: pieces whose vertical centres line up form
/// one row (a table row or a line of text), left to right, with a tab where there is a gap — so a
/// screenshot of a table reads back as a table.
public enum OCRLayout {
    public struct Piece: Sendable {
        public var text: String
        /// Normalised, origin at the bottom left (as Vision reports it).
        public var box: CGRect
        public init(text: String, box: CGRect) { self.text = text; self.box = box }
    }

    public static func rows(_ pieces: [Piece]) -> String {
        var rows: [[Piece]] = []
        for p in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - p.box.midY) < min(first.box.height, p.box.height) * 0.6 {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            var line = ""
            for (i, p) in sorted.enumerated() {
                if i > 0 { line += p.box.minX - sorted[i - 1].box.maxX > p.box.height * 0.8 ? "\t" : " " }
                line += p.text
            }
            return line
        }.joined(separator: "\n")
    }
}
