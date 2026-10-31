import Foundation

/// Word error rate with light normalization, so recognizers are compared on words, not punctuation.
public enum WER {
    /// Words for scoring recognition, not formatting: lowercase, no edge punctuation, hyphens,
    /// dots and @ split, spelled letters joined, spoken "dot" dropped, fillers dropped when asked,
    /// and each run of numbers (words or digits) one token, since number format is cleanup's job.
    public static func normalize(_ s: String, dropFillers: Bool = true) -> [String] {
        var words: [String] = []
        let lowered = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "–", with: " ")
        for raw in lowered.split(whereSeparator: { $0.isWhitespace || $0 == "/" }) {
            var w = String(raw)
            // "$25" and "25%" say "dollars" and "percent".
            let money = w.contains("$"), percent = w.contains("%")
            while let f = w.first, !f.isLetter, !f.isNumber { w.removeFirst() }
            while let l = w.last, !l.isLetter, !l.isNumber { w.removeLast() }
            if w.isEmpty { continue }
            // "p.m." -> "pm"; "sam.lee@example.com" -> sam lee example com; 3.5 and 5:30 stay whole.
            if w.contains(where: \.isLetter) {
                if w.count <= 5, w.split(separator: ".").allSatisfy({ $0.count == 1 }) { w = w.replacingOccurrences(of: ".", with: "") }
                for part in w.split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "@" || $0 == "_" }) { words.append(String(part)) }
            } else {
                words.append(w)
            }
            if money { words.append("dollars") }
            if percent { words.append("percent") }
        }
        var out: [String] = []
        var letters = ""
        var inNumber = false
        func flushLetters() { if !letters.isEmpty { out.append(letters); letters = "" } }
        for w in words {
            if dropFillers && fillers.contains(w) { continue }
            // Spoken punctuation of emails and URLs is formatting, not words.
            if w == "dot" { continue }
            // A run of number words or digits is one token: formatting numbers is cleanup's job.
            if isNumberish(w) || (inNumber && (w == "point" || w == "and")) {
                flushLetters()
                if !inNumber { out.append("<num>"); inNumber = true }
                continue
            }
            inNumber = false
            // Spelled letters ("j d", "p m") join into one token.
            if w.count == 1, w.first!.isLetter, w != "a", w != "i" { letters += w; continue }
            flushLetters()
            out.append(w)
        }
        flushLetters()
        return out
    }

    public static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "twentieth",
    ]

    static func isNumberish(_ w: String) -> Bool {
        if numberWords.contains(w) { return true }
        guard let f = w.first, f.isNumber else { return false }
        // 12,500 / 3.5 / 5:30 / 4th / 21st / 800-555: digits with separators or ordinal suffixes.
        let core = w.replacingOccurrences(of: "st", with: "").replacingOccurrences(of: "nd", with: "")
            .replacingOccurrences(of: "rd", with: "").replacingOccurrences(of: "th", with: "")
        return core.allSatisfy { $0.isNumber || ",.:%-".contains($0) }
    }

    public static let fillers: Set<String> = ["um", "uh", "erm", "er", "ah", "hmm", "mm", "uhm", "umm", "uhh", "mhm"]

    public struct Result: Sendable, Equatable {
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        public var referenceWords: Int
        public var errors: Int { substitutions + deletions + insertions }
        public var rate: Double { referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }

        public static func + (a: Result, b: Result) -> Result {
            Result(substitutions: a.substitutions + b.substitutions, deletions: a.deletions + b.deletions,
                   insertions: a.insertions + b.insertions, referenceWords: a.referenceWords + b.referenceWords)
        }
        public static let zero = Result(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 0)
    }

    public static func compute(reference: String, hypothesis: String) -> Result {
        align(normalize(reference), normalize(hypothesis))
    }

    /// Levenshtein alignment over words with backtrace counts.
    public static func align(_ r: [String], _ h: [String]) -> Result {
        let n = r.count, m = h.count
        if n == 0 { return Result(substitutions: 0, deletions: 0, insertions: m, referenceWords: 0) }
        if m == 0 { return Result(substitutions: 0, deletions: n, insertions: 0, referenceWords: n) }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = r[i - 1] == h[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            }
        }
        var i = n, j = m, s = 0, del = 0, ins = 0
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] != h[j - 1] { s += 1 }
                i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                del += 1; i -= 1
            } else {
                ins += 1; j -= 1
            }
        }
        return Result(substitutions: s, deletions: del, insertions: ins, referenceWords: n)
    }
}
