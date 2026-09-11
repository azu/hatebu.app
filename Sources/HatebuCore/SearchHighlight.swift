import Foundation

/// Map normalized matches back to whole characters in the original display text.
public enum SearchHighlight {
    public static func ranges(in text: String, terms: [String]) -> [NSRange] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        var normalized = "", origins: [NSRange] = []
        for index in text.indices {
            let next = text.index(after: index)
            let piece = Text.normalized(String(text[index..<next]))
            normalized += piece
            origins += Array(repeating: NSRange(index..<next, in: text), count: piece.utf16.count)
        }
        let source = normalized as NSString
        var matches: [NSRange] = []
        for term in Set(terms.map(Text.normalized)).filter({ !$0.isEmpty }) {
            var start = 0
            while start < source.length {
                let found = source.range(of: term, options: .literal, range: NSRange(location: start, length: source.length - start))
                if found.location == NSNotFound { break }
                let first = origins[found.location], last = origins[NSMaxRange(found) - 1]
                matches.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
                start = found.location + 1
            }
        }
        var merged: [NSRange] = []
        for range in matches.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        return merged
    }
}
