import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MurmurCore
import Tokenizers

/// A local instruct model through MLX on the GPU, greedy, with two speed measures:
/// the system prompt's KV cache is kept between dictations, and decoding verifies drafts
/// looked up in the transcript itself (prompt-lookup speculation), since a cleanup is
/// mostly a copy of its input. Speculation needs a trimmable cache (plain attention).
public final class MLXCleaner: Cleaner, @unchecked Sendable {
    public let repo: String
    public let speculate: Bool
    /// A model fine-tuned for this task on this Mac: loaded from a local folder, short prompt.
    public let tunedDirectory: URL?
    public var displayName: String?
    public var name: String {
        displayName ?? ((repo.split(separator: "/").last.map(String.init) ?? repo) + (speculate ? "+lookup" : ""))
    }
    private let engine: Engine
    private var dictionary: [String] = []
    /// Statistics of the most recent call (bench only; not thread-safe across callers).
    public private(set) var lastStats: Stats?

    public init(repo: String, speculate: Bool = true) {
        self.repo = repo
        self.speculate = speculate
        self.tunedDirectory = nil
        self.engine = Engine()
    }

    public init(tunedDirectory: URL, name: String, speculate: Bool = true) {
        self.repo = tunedDirectory.path
        self.speculate = speculate
        self.tunedDirectory = tunedDirectory
        self.displayName = name
        self.engine = Engine()
    }

    private func systemPrompt(_ terms: [String]) -> String {
        tunedDirectory == nil ? CleanupPrompt.system(dictionary: terms) : CleanupPrompt.tunedSystem(dictionary: terms)
    }

    /// Per-call statistics, for the bench.
    public struct Stats: Sendable {
        public var promptTokens = 0
        public var prefilledTokens = 0
        public var outputTokens = 0
        public var modelCalls = 0
        public var acceptedDraftTokens = 0
    }

    public func setDictionary(_ terms: [String]) { dictionary = terms }

    public func load() async throws {
        let config = tunedDirectory.map { ModelConfiguration(directory: $0) } ?? ModelConfiguration(id: repo)
        let ctx = try await #huggingFaceLoadModel(configuration: config)
        await engine.set(ctx)
        _ = try await engine.run(system: systemPrompt(dictionary),
                                 user: CleanupPrompt.user(CleanupRequest(raw: "warm up the model please")),
                                 lookupSource: "warm up the model please", speculate: speculate, onFirst: {})
    }

    public func clean(_ req: CleanupRequest, onFirstToken: @escaping @Sendable () -> Void) async throws -> String {
        let (text, stats) = try await cleanWithStats(req, onFirstToken: onFirstToken)
        lastStats = stats
        return text
    }

    public func cleanWithStats(_ req: CleanupRequest, onFirstToken: @escaping @Sendable () -> Void) async throws -> (String, Stats) {
        let terms = req.dictionary.isEmpty ? dictionary : req.dictionary
        switch req.mode {
        case .dictation:
            let (out, stats) = try await engine.run(system: systemPrompt(terms), user: CleanupPrompt.user(req),
                                                    lookupSource: req.raw, speculate: speculate, onFirst: onFirstToken)
            return (CleanupPrompt.clean(output: out), stats)
        case .command(let selection):
            let (out, stats) = try await engine.run(system: CleanupPrompt.commandSystem,
                                                    user: CleanupPrompt.commandUser(selection: selection, instruction: req.raw, style: req.style),
                                                    lookupSource: selection, speculate: speculate, onFirst: onFirstToken)
            return (CleanupPrompt.clean(output: out), stats)
        }
    }

    /// Voice control's fallback: the model's raw answer (JSON) for one spoken command.
    /// It shares the cleanup model; the next dictation re-reads its own system prompt.
    public func decideControl(_ command: String, appName: String?) async throws -> String {
        let (out, _) = try await engine.run(system: CleanupPrompt.controlSystem,
                                            user: CleanupPrompt.controlUser(command: command, appName: appName),
                                            lookupSource: command, speculate: speculate, onFirst: {})
        return CleanupPrompt.clean(output: out)
    }

    actor Engine {
        private var ctx: ModelContext?
        private var cache: [KVCache] = []
        /// Tokens currently held in `cache`.
        private var cached: [Int] = []

        func set(_ c: ModelContext) {
            ctx = c
            cache = []
            cached = []
        }

        func run(system: String, user: String, lookupSource: String, speculate: Bool,
                 onFirst: @escaping @Sendable () -> Void) throws -> (String, Stats) {
            guard let ctx else { throw CleanerError.failed("model not loaded") }
            let model = ctx.model
            let tok = ctx.tokenizer
            let messages: [[String: any Sendable]] = [["role": "system", "content": system], ["role": "user", "content": user]]
            let prompt = try tok.applyChatTemplate(messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
            var stats = Stats()
            stats.promptTokens = prompt.count

            // Reuse the cached prefix (the system prompt, usually); drop the rest.
            var common = 0
            while common < min(cached.count, prompt.count - 1) && cached[common] == prompt[common] { common += 1 }
            let canTrim = !cache.isEmpty && canTrimPromptCache(cache)
            if cache.isEmpty || !canTrim || common == 0 {
                cache = model.newCache(parameters: nil)
                cached = []
                common = 0
            } else if cached.count > common {
                _ = trimPromptCache(cache, numTokens: cached.count - common)
                cached = Array(cached[..<common])
            }
            let rest = Array(prompt[common...])
            stats.prefilledTokens = rest.count
            var logits = model(MLXArray(rest.map { Int32($0) })[.newAxis, 0...], cache: cache)
            cached += rest
            var next = argMax(logits[0, -1, 0...], axis: -1).item(Int.self)
            onFirst()

            // Keep the system-prompt cache for next time; generation below extends it and is
            // trimmed back at the start of the next call.
            var stop: Set<Int> = []
            if let e = tok.eosTokenId { stop.insert(e) }
            for t in ["<|im_end|>", "<|endoftext|>", "<end_of_turn>", "<|eot_id|>", "</s>"] {
                if let id = tok.convertTokenToId(t) { stop.insert(id) }
            }
            let source = tok.encode(text: lookupSource, addSpecialTokens: false)
            let maxOut = max(64, source.count * 2 + 48)
            let trimmable = canTrimPromptCache(cache)
            var out: [Int] = []

            while out.count < maxOut {
                if stop.contains(next) { break }
                out.append(next)
                let draft = (speculate && trimmable) ? Self.lookup(history: out, source: source, maxDraft: 10) : []
                let input = [next] + draft
                logits = model(MLXArray(input.map { Int32($0) })[.newAxis, 0...], cache: cache)
                stats.modelCalls += 1
                cached += input
                if draft.isEmpty {
                    next = argMax(logits[0, -1, 0...], axis: -1).item(Int.self)
                    continue
                }
                let preds = argMax(logits[0, 0..., 0...], axis: -1).asArray(Int.self)
                var accepted = 0
                while accepted < draft.count && preds[accepted] == draft[accepted] && !stop.contains(draft[accepted]) {
                    accepted += 1
                }
                out += draft[..<accepted]
                stats.acceptedDraftTokens += accepted
                next = preds[accepted]
                let reject = draft.count - accepted
                if reject > 0 {
                    _ = trimPromptCache(cache, numTokens: reject)
                    cached.removeLast(reject)
                }
            }
            stats.outputTokens = out.count
            return (tok.decode(tokenIds: out, skipSpecialTokens: true), stats)
        }

        /// Draft: the tokens that followed the longest recent n-gram (3, then 2, then 1) of
        /// the output where it last appears in the source.
        static func lookup(history: [Int], source: [Int], maxDraft: Int) -> [Int] {
            for n in stride(from: 3, through: 1, by: -1) where history.count >= n && source.count > n {
                let tail = Array(history.suffix(n))
                var i = source.count - n - 1
                while i >= 0 {
                    if Array(source[i..<(i + n)]) == tail {
                        let start = i + n
                        return Array(source[start..<min(start + maxDraft, source.count)])
                    }
                    i -= 1
                }
            }
            return []
        }
    }
}
