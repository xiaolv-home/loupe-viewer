import Foundation

/// Saves an editor's changes without its reformatting: the editor shows the file in its own
/// tidy form (`base`), the user edits that (`edited`), and only the lines the user changed are
/// written over the file as it was on disk (`original`). Everything else keeps its exact bytes.
/// A three-way merge in the manner of diff3; where the editor's tidying and the user's edit
/// touch the same lines, the edit wins.
public enum LineMerge {
    public static func merge(original: String, base: String, edited: String) -> String {
        if edited == base { return original }
        if base == original { return edited }
        let o = lines(original), b = lines(base), e = lines(edited)
        let toOriginal = matches(b, o), toEdited = matches(b, e)
        var out: [Substring] = []
        var i = 0, oi = 0, ei = 0
        while true {
            // Next line of the base that is unchanged in both the original and the edit.
            var j = i
            while j < b.count, !(toOriginal[j].map { $0 >= oi } ?? false && toEdited[j].map { $0 >= ei } ?? false) { j += 1 }
            let oEnd = j < b.count ? toOriginal[j]! : o.count
            let eEnd = j < b.count ? toEdited[j]! : e.count
            // The stretch before it: the user's version if they changed it, else the file's own.
            if Array(e[ei..<eEnd]) == Array(b[i..<j]) { out += o[oi..<oEnd] } else { out += e[ei..<eEnd] }
            guard j < b.count else { break }
            out.append(o[oEnd])
            i = j + 1
            oi = oEnd + 1
            ei = eEnd + 1
        }
        return out.joined(separator: "\n")
    }

    static func lines(_ s: String) -> [Substring] { s.split(separator: "\n", omittingEmptySubsequences: false) }

    /// For each line of `a`, the line of `b` it lines up with (in order), or nil.
    static func matches(_ a: [Substring], _ b: [Substring]) -> [Int?] {
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result = [Int?](repeating: nil, count: a.count)
        var bi = 0
        for ai in a.indices where !removed.contains(ai) {
            while inserted.contains(bi) { bi += 1 }
            result[ai] = bi
            bi += 1
        }
        return result
    }
}
