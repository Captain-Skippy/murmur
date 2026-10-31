import Foundation

/// One term the user wants spelled their way. `sounds` are forms the recognizer produces instead
/// ("kai marrow" for "Kai Merrow"); they are rewritten to `term` after recognition.
public struct DictionaryEntry: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable, Comparable {
        case wispr, learned, manual
        // Precedence when two sources disagree: manual beats learned beats an import.
        private var rank: Int { switch self { case .wispr: 0; case .learned: 1; case .manual: 2 } }
        public static func < (a: Source, b: Source) -> Bool { a.rank < b.rank }
    }

    public var term: String
    public var sounds: [String]
    public var category: String?
    public var source: Source

    public init(term: String, sounds: [String] = [], category: String? = nil, source: Source = .manual) {
        self.term = term
        self.sounds = sounds
        self.category = category
        self.source = source
    }

    var key: String { PersonalDictionary.fold(term) }
}

/// The personal dictionary: used for recognizer biasing, the cleanup prompt, and the
/// post-recognition rewrite of known misrecognitions.
public struct PersonalDictionary: Codable, Sendable, Equatable {
    public private(set) var entries: [DictionaryEntry]
    /// Folded terms the user removed; imports never bring them back.
    public private(set) var removed: Set<String>

    public init(entries: [DictionaryEntry] = [], removed: Set<String> = []) {
        self.entries = []
        self.removed = removed
        merge(entries)
    }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Merge entries in. Same term (case- and accent-insensitive) combines sounds; the
    /// higher-precedence source decides spelling and category. Removed terms are skipped
    /// unless the incoming entry is manual (the user re-adding it).
    public mutating func merge(_ incoming: [DictionaryEntry]) {
        for var e in incoming {
            e.term = e.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !e.term.isEmpty else { continue }
            let k = e.key
            if removed.contains(k) {
                guard e.source == .manual else { continue }
                removed.remove(k)
            }
            if let i = entries.firstIndex(where: { $0.key == k }) {
                var cur = entries[i]
                let winner = e.source >= cur.source ? e : cur
                cur.term = winner.term
                cur.category = winner.category ?? cur.category ?? e.category
                cur.source = max(cur.source, e.source)
                cur.sounds = Self.uniqueSounds(cur.sounds + e.sounds, term: cur.term)
                entries[i] = cur
            } else {
                e.sounds = Self.uniqueSounds(e.sounds, term: e.term)
                entries.append(e)
            }
        }
    }

    /// Set an entry exactly as given (an edit), replacing any entry with the same term.
    public mutating func replace(_ e: DictionaryEntry) {
        let k = PersonalDictionary.fold(e.term)
        removed.remove(k)
        entries.removeAll { $0.key == k }
        var e = e
        e.sounds = Self.uniqueSounds(e.sounds, term: e.term)
        entries.append(e)
    }

    public mutating func remove(term: String) {
        let k = Self.fold(term)
        entries.removeAll { $0.key == k }
        removed.insert(k)
    }

    static func uniqueSounds(_ s: [String], term: String) -> [String] {
        var seen: Set<String> = [fold(term)]
        var out: [String] = []
        for x in s {
            let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = fold(t)
            if t.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(t)
        }
        return out
    }

    /// Terms for recognizer biasing, most specific (longest) first.
    public var biasingTerms: [String] { entries.map(\.term).sorted { $0.count > $1.count } }

    static func compact(_ s: String) -> String { s.filter { !$0.isWhitespace && $0 != "-" } }

    /// Regex for a spoken form: words may run together or split ("BIO2110" for "bio 2110",
    /// "paper clip" for "paperclip"): separators between words are optional, and a long
    /// single word may be split once anywhere.
    static func spokenPattern(_ form: String) -> String {
        let words = form.split(separator: " ").map(String.init)
        if words.count == 1, form.count >= 6, form.allSatisfy(\.isLetter) {
            return form.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s-]?")
        }
        return words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "[\\s-]*")
    }

    /// Rewrite known misrecognitions to the canonical term, whole words only, in one pass so
    /// a replacement is never rewritten again. Longest form wins; also fixes a term's casing.
    public func applyReplacements(to text: String) -> (text: String, count: Int) {
        var forms: [String: String] = [:]  // folded spoken form -> term
        var byCompact: [String: String] = [:]  // same, separators removed, for lookup after a match
        for e in entries {
            forms[Self.fold(e.term)] = e.term
            for s in e.sounds where forms[Self.fold(s)] == nil { forms[Self.fold(s)] = e.term }
        }
        for (k, v) in forms where byCompact[Self.compact(k)] == nil { byCompact[Self.compact(k)] = v }
        guard !forms.isEmpty else { return (text, 0) }
        let alternatives = forms.keys.sorted { $0.count > $1.count }.map(Self.spokenPattern)
        // Not inside an email, domain, path or identifier: no word char, @, / or .word on either side.
        let pattern = "(?<![\\w@./])(?:" + alternatives.joined(separator: "|") + ")(?![\\w@/]|\\.\\w)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return (text, 0) }
        var out = text
        var count = 0
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            guard let term = byCompact[Self.compact(Self.fold(String(out[r])))], out[r] != term else { continue }
            out.replaceSubrange(r, with: term)
            count += 1
        }
        return (out, count)
    }
}

/// A spoken trigger that expands to stored text.
public struct Snippet: Codable, Hashable, Sendable {
    public var trigger: String
    public var expansion: String
    public init(trigger: String, expansion: String) {
        self.trigger = trigger
        self.expansion = expansion
    }
}

public enum Snippets {
    /// Placeholder the cleanup model is told to keep verbatim.
    public static func placeholder(_ i: Int) -> String { "[[S\(i + 1)]]" }

    static func words(_ s: String) -> [String] {
        WER.normalize(s, dropFillers: true)
    }

    /// If the whole utterance is a trigger, return its expansion (skips cleanup entirely).
    public static func wholeUtterance(_ text: String, snippets: [Snippet]) -> Snippet? {
        let w = words(text)
        guard !w.isEmpty else { return nil }
        return snippets.first { words($0.trigger) == w }
    }

    /// Replace each spoken trigger inside the transcript with a placeholder. Returns the
    /// marked text and the snippets in placeholder order.
    public static func mark(_ text: String, snippets: [Snippet]) -> (text: String, used: [Snippet]) {
        var out = text
        var used: [Snippet] = []
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let parts = words(s.trigger)
            guard !parts.isEmpty else { continue }
            let pattern = "(?<![\\w])" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s,.-]+") + "(?![\\w])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = NSRange(out.startIndex..., in: out)
            guard re.firstMatch(in: out, range: ns) != nil else { continue }
            let ph = placeholder(used.count)
            out = re.stringByReplacingMatches(in: out, range: ns, withTemplate: NSRegularExpression.escapedTemplate(for: ph))
            used.append(s)
        }
        return (out, used)
    }

    /// Put the expansions back. A placeholder the model dropped is appended, so nothing is lost.
    public static func expand(_ text: String, used: [Snippet]) -> String {
        var out = text
        for (i, s) in used.enumerated() {
            let ph = placeholder(i)
            if out.contains(ph) {
                out = out.replacingOccurrences(of: ph, with: s.expansion)
            } else {
                out += (out.hasSuffix("\n") || out.isEmpty ? "" : " ") + s.expansion
            }
        }
        return out
    }
}
