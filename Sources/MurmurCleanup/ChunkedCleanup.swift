import Foundation
import MurmurCore

/// Long dictations clean in chunks while the speaker is still talking, so key release waits
/// only for the last chunk. Finished recognizer segments arrive in order; once enough words end
/// on a sentence, that run is cleaned on its own (only the first sees the text before the cursor).
/// Each chunk passes the hard checks on its own, so one bad chunk no longer sends a whole long
/// dictation back to the raw transcript. A dictation that never reaches `minWords` is cleaned
/// in one call, exactly as without chunking.
public actor ChunkedCleanup {
    public struct Config: Sendable {
        /// A chunk closes at the first sentence end after this many words...
        public var minWords = 40
        /// ...or here, sentence end or not.
        public var maxWords = 120
        public init() {}
    }

    private let pipeline: CleanupPipeline
    private let cleaner: any Cleaner
    private let config: Config
    /// The request every chunk starts from (style, app, text before the cursor, screen terms).
    private let context: @Sendable () async -> CleanupRequest
    private var pending: [String] = []
    private var segmentsSeen = 0
    private var chain: Task<[CleanupPipeline.Result], Never>?
    /// Chunks cleaned separately; 0 when the dictation was cleaned in one call.
    public private(set) var chunksStarted = 0

    public init(pipeline: CleanupPipeline, cleaner: any Cleaner, config: Config = Config(),
                context: @escaping @Sendable () async -> CleanupRequest) {
        self.pipeline = pipeline
        self.cleaner = cleaner
        self.config = config
        self.context = context
    }

    /// One finished segment's transcript, in order. Never the tail decoded at release.
    public func add(_ segment: String) {
        segmentsSeen += 1
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        pending.append(s)
        let raw = Self.join(pending)
        let words = raw.split(whereSeparator: \.isWhitespace).count
        let sentenceEnd = raw.last.map { ".?!".contains($0) } ?? false
        if words >= config.maxWords || (words >= config.minWords && sentenceEnd) {
            pending = []
            enqueue(raw)
        }
    }

    private func enqueue(_ raw: String) {
        chunksStarted += 1
        let previous = chain
        let pipeline = pipeline, cleaner = cleaner, context = context
        chain = Task {
            var done = await previous?.value ?? []
            var req = await context()
            req.raw = raw
            // Earlier chunks are not shown: the model copies them into its output.
            if !done.isEmpty { req.textBefore = "" }
            done.append(await Self.clean(req, pipeline: pipeline, cleaner: cleaner))
            return done
        }
    }

    /// All segment transcripts of the dictation, early ones first and the tail last. Cleans
    /// whatever no chunk has taken and returns the whole cleaned text.
    public func finish(parts: [String], onFirstToken: @escaping @Sendable () -> Void = {}) async -> CleanupPipeline.Result {
        let rest = Self.join(pending + parts.dropFirst(segmentsSeen))
        pending = []
        guard let chain else {
            var req = await context()
            req.raw = rest
            return await Self.clean(req, pipeline: pipeline, cleaner: cleaner, onFirstToken: onFirstToken)
        }
        var done = await chain.value
        if !rest.isEmpty {
            var req = await context()
            req.raw = rest
            // Earlier chunks are not shown: the model copies them into its output.
            req.textBefore = ""
            chunksStarted += 1
            done.append(await Self.clean(req, pipeline: pipeline, cleaner: cleaner, onFirstToken: onFirstToken))
        } else {
            onFirstToken()
        }
        let fellBack = done.compactMap(\.fellBack)
        return .init(text: Self.joined(done.map(\.text)), usedModel: done.contains(where: \.usedModel),
                     fellBack: fellBack.isEmpty ? nil : "\(fellBack.count) of \(done.count) chunks: " + fellBack.joined(separator: "; "),
                     rejected: nil)
    }

    private static func clean(_ req: CleanupRequest, pipeline: CleanupPipeline, cleaner: any Cleaner,
                              onFirstToken: @escaping @Sendable () -> Void = {}) async -> CleanupPipeline.Result {
        do { return try await pipeline.run(req, cleaner: cleaner, onFirstToken: onFirstToken) } catch {
            onFirstToken()
            return .init(text: CleanupPipeline.tidy(req.raw, style: req.style), usedModel: false, fellBack: "\(error)")
        }
    }

    /// Segment transcripts joined as `SegmentedSession` joins them.
    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Cleaned chunks joined the way the speaker's text continues: a space, unless a chunk
    /// already ends or starts a line.
    static func joined(_ chunks: [String]) -> String {
        var out = ""
        for c in chunks where !c.isEmpty {
            if !out.isEmpty && !out.hasSuffix("\n") && !c.hasPrefix("\n") { out += " " }
            out += c
        }
        return out
    }
}
