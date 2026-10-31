import Foundation
import MurmurCore

/// Several recognizers decode each segment at once and a word vote settles where they differ
/// (`TranscriptVote`): the first, primary, keeps its text wherever the others do not outvote it.
/// A voter that fails, or is still decoding `grace` after the primary finishes, sits that segment
/// out; with fewer than three readings the primary stands. Only the primary gets the vocabulary:
/// the voters run unbiased.
public final class VotingRecognizer: Recognizer, @unchecked Sendable {
    public let recognizers: [any Recognizer]
    public let grace: Duration
    public var name: String { recognizers[0].name + "+vote" }
    public var maxSegmentSeconds: Double { recognizers.map(\.maxSegmentSeconds).min() ?? 24 }

    public init(_ recognizers: [any Recognizer], grace: Duration = .milliseconds(1200)) {
        precondition(!recognizers.isEmpty)
        self.recognizers = recognizers
        self.grace = grace
    }

    public func load() async throws {
        for r in recognizers { try await r.load() }
    }

    public func setVocabulary(_ terms: [String]) async throws {
        try await recognizers[0].setVocabulary(terms)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let texts = try await Self.collect(recognizers.map { r in { try await r.transcribe(samples) } }, grace: grace)
        return TranscriptVote.vote(texts.compactMap { $0 })
    }

    /// Run every job at once. Index 0 must succeed (its error is thrown); the others count only
    /// if they finish without error within `grace` of job 0. Late jobs keep running detached.
    static func collect(_ jobs: [@Sendable () async throws -> String], grace: Duration) async throws -> [String?] {
        let results = Results(count: jobs.count)
        let tasks = jobs.enumerated().map { i, job in
            Task { await results.set(i, await Result(catching: job)) }
        }
        await tasks[0].value
        let primary = try await results.get(0)!.get()
        // Voters finishing after the deadline are left running and ignored.
        let deadline = ContinuousClock.now + grace
        while await !results.allDone, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        var out: [String?] = [primary]
        for i in 1..<jobs.count { out.append(try? await results.get(i)?.get()) }
        return out
    }

    actor Results {
        private var items: [Result<String, Error>?]
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ r: Result<String, Error>) { items[i] = r }
        func get(_ i: Int) -> Result<String, Error>? { items[i] }
        var allDone: Bool { items.allSatisfy { $0 != nil } }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
