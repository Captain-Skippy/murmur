import Foundation
import MurmurCore

/// Everything cleanup may use. Text only; audio never reaches a cleaner.
public struct CleanupRequest: Sendable {
    public enum Mode: Sendable, Equatable {
        case dictation
        /// Command mode: rewrite `selection` following the spoken instruction (the raw text).
        case command(selection: String)
    }

    public var raw: String
    public var mode: Mode
    public var style: AppStyle
    public var appName: String?
    /// Text just before the cursor, for continuity (capitalization, list numbering).
    public var textBefore: String
    /// Names and identifiers read around the cursor and in the window title.
    public var screenTerms: [String]
    public var dictionary: [String]

    public init(raw: String, mode: Mode = .dictation, style: AppStyle = .neutral, appName: String? = nil,
                textBefore: String = "", screenTerms: [String] = [], dictionary: [String] = []) {
        self.raw = raw
        self.mode = mode
        self.style = style
        self.appName = appName
        self.textBefore = textBefore
        self.screenTerms = screenTerms
        self.dictionary = dictionary
    }
}

public protocol Cleaner: AnyObject, Sendable {
    var name: String { get }
    func load() async throws
    /// Clean one transcript. `onFirstToken` fires once when output starts.
    func clean(_ req: CleanupRequest, onFirstToken: @escaping @Sendable () -> Void) async throws -> String
}

/// No model: the recognizer's own punctuation and casing, plus the deterministic steps.
public final class PassthroughCleaner: Cleaner, @unchecked Sendable {
    public let name = "none"
    public init() {}
    public func load() async throws {}
    public func clean(_ req: CleanupRequest, onFirstToken: @escaping @Sendable () -> Void) async throws -> String {
        onFirstToken()
        return req.raw
    }
}

/// The cleanup stage around any cleaner: dictionary spellings, snippets, the fast path,
/// and a last check that the output is still the speaker's words.
public struct CleanupPipeline: Sendable {
    public struct Result: Sendable {
        public var text: String
        public var usedModel: Bool
        /// Set when the model output failed a hard check and the transcript was used instead.
        public var fellBack: String?
        /// The model output that was rejected, for the bench and debug logs only.
        public var rejected: String?

        public init(text: String, usedModel: Bool, fellBack: String? = nil, rejected: String? = nil) {
            self.text = text
            self.usedModel = usedModel
            self.fellBack = fellBack
            self.rejected = rejected
        }
    }

    public var dictionary: PersonalDictionary
    public var snippets: [Snippet]

    public init(dictionary: PersonalDictionary, snippets: [Snippet]) {
        self.dictionary = dictionary
        self.snippets = snippets
    }

    /// Short, already clean utterances skip the model: no fillers, no correction cues, no
    /// spoken formatting commands, no numbers or symbols to format.
    public static func isTriviallyClean(_ raw: String) -> Bool {
        let words = raw.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 8 else { return false }
        let lower = " " + raw.lowercased() + " "
        let cues = [" um", " uh", " erm", " hmm", " like,", " i mean", " no,", " no wait", " actually", " scratch that",
                    " sorry", " new line", " newline", " new paragraph", " bullet", " number ", " at ", " dot ",
                    " comma", " period", " slash", " dash", " colon", " quote", " you know", " make that", " rather",
                    " percent", " dollars", " o'clock"]
        if cues.contains(where: lower.contains) { return false }
        let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                           "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "first", "second", "third"]
        let ws = Set(WER.normalize(raw, dropFillers: false))
        if !ws.isDisjoint(with: numberWords) { return false }
        // Repeated words are stutters or false starts.
        let norm = WER.normalize(raw, dropFillers: false)
        for i in 1..<max(norm.count, 1) where norm[i] == norm[i - 1] { return false }
        return true
    }

    public func run(_ req: CleanupRequest, cleaner: any Cleaner,
                    onFirstToken: @escaping @Sendable () -> Void) async throws -> Result {
        var req = req
        if case .dictation = req.mode { req.raw = SpokenFormat.apply(req.raw, style: req.style) }
        req.raw = dictionary.applyReplacements(to: req.raw).text
        req.dictionary = dictionary.biasingTerms

        if case .dictation = req.mode, let s = Snippets.wholeUtterance(req.raw, snippets: snippets) {
            onFirstToken()
            return Result(text: s.expansion, usedModel: false)
        }
        let marked = Snippets.mark(req.raw, snippets: snippets)
        req.raw = marked.text

        if cleaner is PassthroughCleaner || (req.mode == .dictation && Self.isTriviallyClean(req.raw)) {
            onFirstToken()
            let text = Snippets.expand(Self.tidy(req.raw, style: req.style), used: marked.used)
            return Result(text: dictionary.applyReplacements(to: text).text, usedModel: false)
        }

        var out = try await cleaner.clean(req, onFirstToken: onFirstToken)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        var fellBack: String?
        var rejected: String?
        if case .dictation = req.mode {
            let failures = HardChecks.run(raw: req.raw, output: out).filter { [.answered, .added, .dropped, .numbers].contains($0.kind) }
            if out.isEmpty || !failures.isEmpty {
                fellBack = out.isEmpty ? "empty output" : failures.map(\.description).joined(separator: "; ")
                rejected = out
                out = Self.tidy(req.raw, style: req.style)
            }
        }
        out = Snippets.expand(out, used: marked.used)
        return Result(text: dictionary.applyReplacements(to: out).text, usedModel: true, fellBack: fellBack, rejected: rejected)
    }

    /// Minimal formatting without a model: trim, capitalize the first letter, and in casual
    /// style drop a lone trailing period.
    public static func tidy(_ s: String, style: AppStyle) -> String {
        // Standalone "um"/"uh" (and the comma around them) never carry meaning.
        var t = s.replacingOccurrences(of: #"(?i)(?:,\s*)?\b(?:um+|uh+|erm)\b,?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
        if style == .casual, t.hasSuffix("."), !t.dropLast().contains(where: { ".!?".contains($0) }) { t.removeLast() }
        return t
    }
}
