import Foundation

/// Deterministic checks on a cleanup: the output must be the speaker's words, reformatted.
/// It must not answer or obey the content, add meaning, drop meaning, or misspell a
/// dictionary term. Heuristic for free speech; exact for scripted items with expectations.
public enum HardChecks {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case answered, added, dropped, dictionary, numbers, expectation
    }

    public struct Failure: Codable, Sendable, Equatable, CustomStringConvertible {
        public var kind: Kind
        public var detail: String
        public var description: String { "\(kind.rawValue): \(detail)" }
    }

    /// What a scripted utterance must and must not produce.
    public struct Expectation: Codable, Sendable, Equatable {
        public var mustContain: [String]
        public var mustNotContain: [String]
        /// The utterance is a question or instruction that must be transcribed, not acted on.
        public var mustNotObey: Bool
        public init(mustContain: [String] = [], mustNotContain: [String] = [], mustNotObey: Bool = false) {
            self.mustContain = mustContain
            self.mustNotContain = mustNotContain
            self.mustNotObey = mustNotObey
        }
    }

    static let assistantOpeners = [
        "sure", "certainly", "of course", "absolutely", "here's", "here is", "here are", "i'd be happy",
        "i would be happy", "i can help", "i can't", "i cannot", "as an ai", "great question", "subject:",
        "dear ", "hi sam", "hello!", "okay, here", "ok, here", "i'm sorry", "sorry, i", "the answer",
        "to answer", "i don't have", "happy to",
    ]

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "for", "with", "at", "by", "is", "are",
        "was", "were", "be", "it", "its", "it's", "this", "that", "i", "you", "we", "they", "he", "she", "me", "my",
        "your", "our", "as", "if", "then", "just", "like", "also", "too", "very", "really", "yeah", "okay", "ok",
        "well", "oh", "you know", "know", "mean", "kind", "sort", "basically", "actually", "literally", "right",
    ]

    /// Words that legitimately disappear when speech becomes formatted text.
    static let formattingWords: Set<String> = [
        "dot", "at", "slash", "backslash", "dash", "hyphen", "colon", "semicolon", "underscore", "percent", "point",
        "comma", "period", "full", "stop", "new", "line", "paragraph", "bullet", "number", "numbered", "quote",
        "unquote", "open", "close", "paren", "parenthesis", "bracket", "hashtag", "hash", "dollar", "dollars",
        "cents", "o'clock", "am", "pm", "a.m", "p.m", "question", "mark", "exclamation", "tick", "backtick",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "oh",
        "twentieth", "thirtieth", "st", "nd", "rd", "th", "com", "org", "edu", "net", "io",
    ]

    /// Cues that the speaker corrected themselves, so dropped words are expected.
    static let correctionCues = [
        "no,", "no wait", "i mean", "actually", "scratch that", "sorry", "rather", "make that", "not ", "wait",
        "never mind", "nevermind", "correction", "or no",
    ]

    /// Alphanumeric pieces of normalized words: "sam@gmail.com" -> sam, gmail, com. Runs of
    /// spelled letters ("c j") also yield their joined form ("cj").
    static func parts(_ s: String) -> [String] {
        let p = WER.normalize(s).flatMap { w in
            w.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        }
        var joined: [String] = []
        var run = ""
        for w in p + [""] {
            if w.count == 1 && w.first!.isLetter { run += w; continue }
            if run.count > 1 { joined.append(run) }
            run = ""
        }
        return p + joined
    }

    /// Words of plain prose only: tokens with @ / _ or inner dots (emails, URLs, paths,
    /// identifiers) are left out.
    static func standaloneParts(_ s: String) -> [String] {
        let prose = s.split(whereSeparator: \.isWhitespace).filter { t in
            let core = t.trimmingCharacters(in: .punctuationCharacters)
            return !core.contains("@") && !core.contains("/") && !core.contains("_") && !core.contains(".")
        }.joined(separator: " ")
        return parts(prose)
    }

    static func isContent(_ w: String) -> Bool {
        w.count > 1 && !stopwords.contains(w) && !formattingWords.contains(w) && !WER.fillers.contains(w)
            && !w.contains(where: \.isNumber)
    }

    public static func run(raw: String, output: String, dictionaryTerms: [String] = [],
                           expectation: Expectation? = nil) -> [Failure] {
        var failures: [Failure] = []
        let rawLower = raw.lowercased()
        let outTrim = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let outLower = outTrim.lowercased()

        // 1. Assistant voice: the model answered or obeyed instead of transcribing.
        for opener in assistantOpeners where outLower.hasPrefix(opener) {
            let rawStart = WER.normalize(raw).prefix(4).joined(separator: " ")
            let openerStart = WER.normalize(opener).joined(separator: " ")
            if !rawStart.hasPrefix(openerStart) {
                failures.append(.init(kind: .answered, detail: "output opens like an assistant: \"\(opener)\""))
                break
            }
        }

        let rawParts = parts(raw)
        let outParts = parts(output)
        let rawSet = Set(rawParts)
        let outSet = Set(outParts)
        let termParts = Set(dictionaryTerms.flatMap(parts))

        // 2. Added content: new content words the speaker never said.
        let novel = outParts.filter { isContent($0) && !rawSet.contains($0) && !termParts.contains($0) }
        let rawContentCount = max(rawParts.filter(isContent).count, 1)
        let novelUnique = Array(NSOrderedSet(array: novel)) as! [String]
        // A clause the speaker never said: four or more new words in a row (stopwords included).
        // Measured by alignment: a run of inserted words relative to the transcript.
        var run = 0, longest = 0
        let plainRaw = rawParts.filter { !WER.fillers.contains($0) }
        for op in Consensus.alignOps(plainRaw, outParts) {
            if case .ins(let j) = op, !outParts[j].contains(where: \.isNumber), !formattingWords.contains(outParts[j]) {
                run += 1; longest = max(longest, run)
            } else if case .del = op { continue } else { run = 0 }
        }
        if longest >= 4 {
            failures.append(.init(kind: .added, detail: "\(longest) new words in a row"))
        } else if novelUnique.count > max(2, rawContentCount / 6) {
            failures.append(.init(kind: .added, detail: "new words: " + novelUnique.prefix(8).joined(separator: ", ")))
        }
        let rawWords = max(rawParts.filter { !WER.fillers.contains($0) }.count, 1)
        if Double(outParts.count) > Double(rawWords) * 1.4 + 3 {
            failures.append(.init(kind: .added, detail: "output \(outParts.count) words from \(rawWords) spoken"))
        }

        // 3. Dropped content: spoken content words missing, beyond what a self-correction explains.
        let corrected = correctionCues.contains { rawLower.contains($0) }
        let missing = rawParts.filter { isContent($0) && !outSet.contains($0) && !termParts.contains($0) }
        let missingUnique = Array(NSOrderedSet(array: missing)) as! [String]
        let allowedMissing = corrected ? max(4, rawContentCount / 3) : max(2, rawContentCount / 8)
        if missingUnique.count > allowedMissing {
            failures.append(.init(kind: .dropped, detail: "missing: " + missingUnique.prefix(8).joined(separator: ", ")))
        }

        // 4. Dictionary: a term spoken as words must appear spelled exactly. Terms inside an
        //    email, URL, path or identifier ("sam.lee@", MURMUR_SIGN_IDENTITY) are not judged.
        for term in dictionaryTerms {
            let tp = parts(term)
            guard !tp.isEmpty, containsSequence(standaloneParts(raw), tp) || containsSequence(standaloneParts(output), tp) else { continue }
            if !output.contains(term) && containsSequence(standaloneParts(output), tp) || !containsSequence(parts(output), tp) {
                failures.append(.init(kind: .dictionary, detail: "expected \"\(term)\""))
            }
        }

        // 5. Numbers: digits are meaning. Output digits must come from the transcript (unless
        //    it has number words to convert), and transcript numbers must survive unless the
        //    speaker corrected themselves.
        let rawNums = digitRuns(raw), outNums = digitRuns(output)
        let rawHasNumberWords = rawLower.split(whereSeparator: { !$0.isLetter }).contains { WER.numberWords.contains(String($0)) }
        if !rawHasNumberWords {
            let rawJoined = rawNums.joined(separator: "|")
            for n in outNums where !rawJoined.contains(n) {
                failures.append(.init(kind: .numbers, detail: "number \(n) not spoken"))
            }
        }
        if !corrected {
            let outJoined = outNums.joined(separator: "|")
            for n in rawNums where !outJoined.contains(n) {
                failures.append(.init(kind: .numbers, detail: "number \(n) dropped or changed"))
            }
        }

        // 6. Scripted expectations.
        if let e = expectation {
            for s in e.mustContain where !output.contains(s) {
                failures.append(.init(kind: .expectation, detail: "missing \"\(s)\""))
            }
            for s in e.mustNotContain where outLower.contains(s.lowercased()) {
                failures.append(.init(kind: .expectation, detail: "contains \"\(s)\""))
            }
            if e.mustNotObey && raw.contains("?") && !output.contains("?") {
                failures.append(.init(kind: .answered, detail: "question lost its question mark"))
            }
        }
        return failures
    }

    /// Digit runs with separators removed: "5:30" and "5.30" -> "530", "800-555-0198" -> "8005550198".
    static func digitRuns(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var pendingSep = false
        for ch in s {
            if ch.isNumber { cur.append(ch); pendingSep = false }
            else if !cur.isEmpty && ",.:-".contains(ch) && !pendingSep { pendingSep = true }
            else { if !cur.isEmpty { out.append(cur) }; cur = ""; pendingSep = false }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func containsSequence(_ hay: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return true }
        return false
    }
}
