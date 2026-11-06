import Foundation

public enum CSVSniffer {
    /// Guesses a delimiter when several lines have the same, non-zero count of it.
    public static func sniffDelimiter(_ text: String) -> UInt8? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(20).map(String.init)
        guard lines.count >= 2 else { return nil }
        for (d, ch) in [(UInt8(9), Character("\t")), (UInt8(44), Character(",")), (UInt8(59), Character(";")), (UInt8(124), Character("|"))] {
            let counts = lines.dropLast().map { line in line.filter { $0 == ch }.count }
            guard let first = counts.first, first > 0 else { continue }
            if counts.allSatisfy({ $0 == first }) { return d }
        }
        return nil
    }
}
