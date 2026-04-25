import Foundation

enum Tokenize {
    /// Lower-cased word-ish tokens, length ≥ 2. Splits on whitespace and
    /// non-word/underscore characters, keeping CJK characters intact (Foundation
    /// regex's \W+ matches non-word; CJK are word characters in Unicode).
    static func tokens(in text: String) -> Set<String> {
        let lowered = text.lowercased()
        let parts = lowered.split { c in
            !(c.isLetter || c.isNumber)
        }
        return Set(parts.compactMap { piece -> String? in
            let s = String(piece)
            return s.count >= 2 ? s : nil
        })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let uni = a.union(b).count
        return Double(inter) / Double(uni)
    }
}
