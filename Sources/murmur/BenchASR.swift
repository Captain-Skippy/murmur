import Foundation
import MurmurASR
import MurmurCore

/// One recognizer run over one eval item, saved so later stages reuse it without re-decoding.
struct ASRResultRow: Codable {
    var id: String
    var stack: String
    var text: String
    var tailMs: Double
    var wholeMs: Double?
    var wholeText: String?
    var segments: Int
    /// Slowest segment decode as a fraction of its audio length; above 1 means the
    /// recognizer would fall behind live speech.
    var maxSegmentRTF: Double
}

enum BenchASR {
    static func resultsURL(set: EvalSet, stack: String) -> URL {
        set.dir.appendingPathComponent("results/asr-\(stack).jsonl")
    }

    static func loadResults(set: EvalSet, stack: String) -> [String: ASRResultRow] {
        guard let d = try? Data(contentsOf: resultsURL(set: set, stack: stack)) else { return [:] }
        var out: [String: ASRResultRow] = [:]
        for line in d.split(separator: 0x0A) {
            if let r = try? JSONDecoder().decode(ASRResultRow.self, from: Data(line)) { out[r.id] = r }
        }
        return out
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// Decode like live dictation: segments before the last pause decode "during speech"
    /// (untimed, but their real-time factor is recorded); the tail is what release waits for.
    static func run(stack: String, set: EvalSet, items: [EvalItem], vocabulary: [String], whole: Bool) async throws -> [ASRResultRow] {
        let rec = try RecognizerStacks.make(stack)
        let memBefore = residentMB()
        let t0 = monotonicNanos()
        try await rec.load()
        try await rec.setVocabulary(vocabulary)
        let loadMs = Double(monotonicNanos() - t0) / 1e6
        log("\(stack): loaded and warm in \(Int(loadMs)) ms, +\(Int(residentMB() - memBefore)) MB resident")

        let url = resultsURL(set: set, stack: stack)
        try MurmurPaths.ensurePrivate(url.deletingLastPathComponent())
        var rows: [ASRResultRow] = []
        var cfg = PauseSegmenter.Config()
        cfg.maxSegmentSec = rec.maxSegmentSeconds
        for (n, item) in items.enumerated() {
            let samples = try AudioFile.read16k(set.audioURL(item))
            let cuts = PauseSegmenter.cuts(for: samples, config: cfg)
            var bounds = [0] + cuts
            bounds.append(samples.count)
            var parts: [String] = []
            var maxRTF = 0.0
            var tailMs = 0.0
            for i in 0..<(bounds.count - 1) {
                var seg = Array(samples[bounds[i]..<bounds[i + 1]])
                if seg.count < 8_000 { seg += [Float](repeating: 0, count: 8_000 - seg.count) }
                let s = monotonicNanos()
                parts.append(try await rec.transcribe(seg))
                let ms = Double(monotonicNanos() - s) / 1e6
                maxRTF = max(maxRTF, ms / 1000 / (Double(seg.count) / 16_000))
                if i == bounds.count - 2 { tailMs = ms }
            }
            var row = ASRResultRow(id: item.id, stack: stack, text: SegmentedSession.join(parts), tailMs: tailMs,
                                   segments: bounds.count - 1, maxSegmentRTF: maxRTF)
            if whole {
                let s = monotonicNanos()
                row.wholeText = try await rec.transcribe(samples)
                row.wholeMs = Double(monotonicNanos() - s) / 1e6
            }
            rows.append(row)
            if (n + 1) % 50 == 0 { log("\(stack): \(n + 1)/\(items.count)") }
        }
        // Merge with earlier results for other items; never drop them.
        var merged = loadResults(set: set, stack: stack)
        for r in rows { merged[r.id] = r }
        let enc = JSONEncoder()
        var out = Data()
        for r in merged.values.sorted(by: { $0.id < $1.id }) { out.append(try enc.encode(r)); out.append(0x0A) }
        try out.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return rows
    }

    struct Summary {
        var stack: String
        var n: Int
        var tail: LatencySummary
        var whole: LatencySummary
        var wer: Double
        var wholeWer: Double?
        var byCategory: [String: Double]
        var termRecall: (hit: Int, total: Int)
        var termFalse: Int
        var maxRTF: Double
    }

    /// Reference text: hand-checked words when known, else Wispr's recognizer output
    /// (agreement with Wispr, not true WER; the table says which).
    static func reference(_ item: EvalItem) -> String? { item.reference ?? item.wisprASR }

    static func summarize(stack: String, items: [EvalItem], rows: [String: ASRResultRow], terms: [String]) -> Summary {
        var total = WER.Result.zero
        var wholeTotal = WER.Result.zero
        var hasWhole = false
        var cat: [String: WER.Result] = [:]
        var tails: [Double] = []
        var wholes: [Double] = []
        var hit = 0, termsSeen = 0, falseTerms = 0
        var maxRTF = 0.0
        var n = 0
        for item in items {
            guard let r = rows[item.id], let ref = reference(item) else { continue }
            n += 1
            let w = WER.compute(reference: ref, hypothesis: r.text)
            total = total + w
            for c in item.categories { cat[c, default: .zero] = cat[c, default: .zero] + w }
            tails.append(r.tailMs)
            maxRTF = max(maxRTF, r.maxSegmentRTF)
            if let wt = r.wholeText, let wm = r.wholeMs {
                hasWhole = true
                wholes.append(wm)
                wholeTotal = wholeTotal + WER.compute(reference: ref, hypothesis: wt)
            }
            // Dictionary terms: judged against Wispr's formatted text, case-insensitively,
            // because casing is the cleanup stage's job.
            let truth = (item.expectedText ?? item.wisprText ?? ref).lowercased()
            let hyp = r.text.lowercased()
            for t in terms where t.count > 2 {
                let lt = t.lowercased()
                let inTruth = truth.contains(lt), inHyp = hyp.contains(lt)
                if inTruth { termsSeen += 1; if inHyp { hit += 1 } } else if inHyp { falseTerms += 1 }
            }
        }
        return Summary(stack: stack, n: n, tail: LatencySummary(tails), whole: LatencySummary(wholes), wer: total.rate,
                       wholeWer: hasWhole ? wholeTotal.rate : nil, byCategory: cat.mapValues(\.rate),
                       termRecall: (hit, termsSeen), termFalse: falseTerms, maxRTF: maxRTF)
    }

    static func printTable(_ sums: [Summary], categories: [String], refKind: String) {
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        func p(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "-" }
        print("\nRecognition, \(refKind). Latency in ms on this Mac; tail = key release to final text.")
        var header = ["stack", "n", "tail p50", "tail p95", "whole p50", "whole p95", "max RTF", "WER", "WER whole"]
        header += categories.map { "WER \($0)" }
        header += ["terms", "false terms"]
        var rows: [[String]] = [header]
        for s in sums {
            var r = [s.stack, "\(s.n)", f(s.tail.p50), f(s.tail.p95), f(s.whole.p50), f(s.whole.p95),
                     String(format: "%.3f", s.maxRTF), p(s.wer), p(s.wholeWer)]
            r += categories.map { p(s.byCategory[$0]) }
            r += ["\(s.termRecall.hit)/\(s.termRecall.total)", "\(s.termFalse)"]
            rows.append(r)
        }
        printAligned(rows)
    }
}

func printAligned(_ rows: [[String]]) {
    guard let first = rows.first else { return }
    var widths = [Int](repeating: 0, count: first.count)
    for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
    for (k, r) in rows.enumerated() {
        print(r.enumerated().map { i, c in i == 0 ? c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            : String(repeating: " ", count: widths[i] - c.count) + c }.joined(separator: "  "))
        if k == 0 { print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")) }
    }
}

func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
