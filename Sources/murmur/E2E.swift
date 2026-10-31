import Foundation
import MurmurASR
import MurmurCleanup
import MurmurCore

/// Key release to text, headless and the way the app runs it: audio arrives in real time into a
/// `SegmentedSession` (segments decode while the speaker talks, so voters and backlogs compete as
/// they would live), release decodes the tail, then the cleanup pipeline. Insertion (a paste,
/// tens of ms) is not included. Outputs are saved as a cleanup result (asr "e2e-RECOGNIZER") so
/// `ceiling score --candidates` can grade exactly what this pipeline produced. With `chunkWords`
/// cleanup runs in chunks during the audio, as the app does (asr "e2e-RECOGNIZER-chunkN").
enum E2E {
    struct Row: Codable {
        var id: String
        var seconds: Double
        var asrTailMs: Double
        var cleanupMs: Double
        var releaseToTextMs: Double
    }

    static func asrName(_ recognizer: String, _ chunkWords: Int?) -> String {
        "e2e-\(recognizer)" + (chunkWords.map { "-chunk\($0)" } ?? "")
    }

    static func url(_ set: EvalSet, _ recognizer: String, _ cleaner: String) -> URL {
        set.dir.appendingPathComponent("results/e2e-\(recognizer)-\(cleaner).jsonl")
    }

    static func run(set: EvalSet, items: [EvalItem], recognizer: String, cleaner: String, speed: Double,
                    chunkWords: Int? = nil) async throws {
        let asr = asrName(recognizer, chunkWords)
        let (dict, snippets) = DictionaryFile.load()
        let rec = try RecognizerStacks.make(recognizer)
        let mem0 = BenchASR.residentMB()
        try await rec.load()
        try await rec.setVocabulary(dict.biasingTerms)
        let c = try CleanerStacks.make(cleaner)
        if let m = c as? MLXCleaner { m.setDictionary(dict.biasingTerms) }
        try await c.load()
        log("e2e: \(recognizer) + \(cleaner) loaded, +\(Int(BenchASR.residentMB() - mem0)) MB resident")
        let pipeline = CleanupPipeline(dictionary: dict, snippets: snippets)
        var rows: [Row] = [], outs: [CleanupRow] = []
        for (n, item) in items.enumerated() {
            let samples = try AudioFile.read16k(set.audioURL(item))
            let session = SegmentedSession(recognizer: rec)
            let style = AppStyle.resolve(bundleID: item.app)
            let base = CleanupRequest(raw: "", style: style, appName: BenchCleanup.appName(item.app),
                                      screenTerms: Array((item.screenTerms ?? []).prefix(30)))
            var config = ChunkedCleanup.Config()
            if let w = chunkWords { config.minWords = w; config.maxWords = 3 * w }
            let chunker = chunkWords.map { _ in ChunkedCleanup(pipeline: pipeline, cleaner: c, config: config) { base } }
            if let chunker { await session.setOnSegment { await chunker.add($0) } }
            let chunk = 1_600  // 100 ms, about what the capture tap delivers
            let start = ContinuousClock.now
            var i = 0
            while i < samples.count {
                let j = min(i + chunk, samples.count)
                await session.append(Array(samples[i..<j]))
                i = j
                try await Task.sleep(until: start + .microseconds(Int(Double(i) / 16 * 1000 / speed)), clock: .continuous)
            }
            let t0 = monotonicNanos()
            let parts = try await session.finishParts()
            let raw = SegmentedSession.join(parts)
            let t1 = monotonicNanos()
            var req = base
            req.raw = raw
            let result: CleanupPipeline.Result
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = .init(text: "", usedModel: false)
            } else if let chunker {
                result = await chunker.finish(parts: parts)
            } else {
                result = try await pipeline.run(req, cleaner: c) {}
            }
            let t2 = monotonicNanos()
            let ms = { (a: UInt64, b: UInt64) in Double(b - a) / 1e6 }
            rows.append(Row(id: item.id, seconds: item.seconds, asrTailMs: ms(t0, t1), cleanupMs: ms(t1, t2), releaseToTextMs: ms(t0, t2)))
            outs.append(CleanupRow(id: item.id, cleaner: cleaner, asr: asr, raw: raw, output: result.text,
                                   usedModel: result.usedModel, fellBack: result.fellBack, rejected: result.rejected,
                                   ttftMs: 0, totalMs: ms(t1, t2), promptTokens: nil, prefilledTokens: nil, outputTokens: nil,
                                   modelCalls: nil, acceptedDraft: nil, failures: []))
            if (n + 1) % 10 == 0 { log("e2e: \(n + 1)/\(items.count)") }
        }
        log("e2e: peak +\(Int(BenchASR.residentMB() - mem0)) MB resident")
        try Ceiling.save(rows, url(set, String(asr.dropFirst(4)), cleaner))
        try Ceiling.save(outs, BenchCleanup.resultsURL(set: set, cleaner: cleaner, asr: asr))
        summarize(set: set, recognizer: String(asr.dropFirst(4)), cleaner: cleaner, rows: rows)
    }

    static func summarize(set: EvalSet, recognizer: String, cleaner: String, rows: [Row]) {
        func s(_ v: [Double]) -> [String] {
            let l = LatencySummary(v)
            return [l.p50, l.p95].map { $0.map { String(format: "%.0f", $0) } ?? "-" }
        }
        print("\nKey release to text, headless, real-time audio (\(set.name), \(rows.count) items). Latency in ms.")
        printAligned([["stack", "n", "release to text p50", "p95", "max", "asr tail p50", "p95", "cleanup p50", "p95"],
                      ["\(recognizer) + \(cleaner)", "\(rows.count)"] + s(rows.map(\.releaseToTextMs))
                        + [String(format: "%.0f", rows.map(\.releaseToTextMs).max() ?? 0)]
                        + s(rows.map(\.asrTailMs)) + s(rows.map(\.cleanupMs))])
    }
}
