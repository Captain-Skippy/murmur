import Foundation

/// Finds words the user corrected soon after an insertion, to propose (never silently add)
/// dictionary entries. Compares the focused field right after insertion with a later read.
public enum CorrectionDetector {
    public struct Proposal: Codable, Sendable, Equatable, Hashable {
        public var heard: String     // what Murmur inserted
        public var corrected: String // what the user changed it to
        public init(heard: String, corrected: String) {
            self.heard = heard
            self.corrected = corrected
        }
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"()[]")) }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein similarity of two words, case-insensitive, 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Word substitutions between the field right after insertion and later, limited to
    /// words Murmur inserted, that look like spelling fixes (similar spelling or a casing
    /// fix), one or two words at a time. Rewrites of whole phrases are not spelling fixes.
    public static func proposals(inserted: String, fieldAfterInsert: String, fieldLater: String) -> [Proposal] {
        let insertedWords = Set(words(inserted))
        let a = words(fieldAfterInsert), b = words(fieldLater)
        guard a != b, abs(a.count - b.count) <= 60 else { return [] }
        let ops = Consensus.alignOps(a, b)
        var out: [Proposal] = []
        var i = 0
        while i < ops.count {
            guard case .sub = ops[i] else { i += 1; continue }
            // A run of substitutions longer than two is a rewrite.
            var j = i
            while j + 1 < ops.count, case .sub = ops[j + 1] { j += 1 }
            if j - i < 2 {
                for k in i...j {
                    guard case .sub(let x, let y) = ops[k] else { continue }
                    let heard = a[x], fixed = b[y]
                    let spelling = similarity(heard, fixed) >= 0.5 || heard.lowercased() == fixed.lowercased()
                    if insertedWords.contains(heard), heard.count >= 3, fixed.count >= 2, spelling,
                       fixed.contains(where: \.isLetter) {
                        out.append(Proposal(heard: heard, corrected: fixed))
                    }
                }
            }
            i = j + 1
        }
        return out
    }
}
