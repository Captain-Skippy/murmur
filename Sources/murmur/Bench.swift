import Foundation
import MurmurCleanup
import MurmurCore

/// `murmur bench`: one table per candidate stack (recognizer + cleanup), composed from the
/// saved stage results, computing whatever is missing. Latency is headless: key release to
/// text excludes capture start and insertion, which the app's own timing log measures.
enum Bench {
    struct StackResult {
        var name: String
        var asrTail: LatencySummary
        var cleanup: LatencySummary
        var releaseToText: LatencySummary
        var werScripted: WER.Result?
        var werScriptedByCat: [String: Double]
        var werWispr: Double?
        var judge: (win: Int, tie: Int, loss: Int)?
        var judgeFlags: [String: Int]
        var hardFailures: [String: Int]
        var expectationFails: Int
    }

    static func run(stacks: [(asr: String, cleaner: String)], judgeModel: String) async throws -> [StackResult] {
        let wispr = try EvalSet.load("wispr")
        let scripted = try? EvalSet.load("scripted")
        let wItems = wispr.items.filter { $0.seconds <= 30 && $0.excluded == nil && $0.isTest }
        let sItems = scripted?.items.filter { $0.excluded == nil } ?? []
        let terms = DictionaryFile.load().0.biasingTerms
        var out: [StackResult] = []
        for (asr, cleaner) in stacks {
            // Recognition on both sets.
            var wAsr = BenchASR.loadResults(set: wispr, stack: asr)
            let wMissing = wItems.filter { wAsr[$0.id] == nil }
            if !wMissing.isEmpty { for r in try await BenchASR.run(stack: asr, set: wispr, items: wMissing, vocabulary: terms, whole: false) { wAsr[r.id] = r } }
            var sAsr: [String: ASRResultRow] = [:]
            if let scripted {
                sAsr = BenchASR.loadResults(set: scripted, stack: asr)
                let m = sItems.filter { sAsr[$0.id] == nil }
                if !m.isEmpty { for r in try await BenchASR.run(stack: asr, set: scripted, items: m, vocabulary: terms, whole: false) { sAsr[r.id] = r } }
            }
            // Cleanup of this recognizer's transcripts, on both sets.
            var wClean = BenchCleanup.load(set: wispr, cleaner: cleaner, asr: asr)
            let wcMissing = wItems.filter { wClean[$0.id] == nil && wAsr[$0.id] != nil }
            if !wcMissing.isEmpty { for r in try await BenchCleanup.run(cleanerName: cleaner, asr: asr, set: wispr, items: wcMissing) { wClean[r.id] = r } }
            var sClean: [String: CleanupRow] = [:]
            if let scripted {
                sClean = BenchCleanup.load(set: scripted, cleaner: cleaner, asr: asr)
                let m = sItems.filter { sClean[$0.id] == nil && sAsr[$0.id] != nil }
                if !m.isEmpty { for r in try await BenchCleanup.run(cleanerName: cleaner, asr: asr, set: scripted, items: m) { sClean[r.id] = r } }
            }
            // Judge end to end against Wispr; "spoken" is the recognizer consensus.
            let judgeURL = wispr.dir.appendingPathComponent("results/judge-e2e-\(asr)-\(cleaner)-\(CleanupPrompt.version).jsonl")
            var verdicts: [Judge.Verdict] = []
            if let d = try? Data(contentsOf: judgeURL) {
                verdicts = d.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Judge.Verdict.self, from: Data($0)) }
            } else {
                let ref = Judge.SpokenReference(set: wispr)
                let pairs = wItems.compactMap { i -> (id: String, app: String?, spoken: String, murmur: String, wispr: String)? in
                    guard let c = wClean[i.id], let w = i.wisprText else { return nil }
                    return (i.id, BenchCleanup.appName(i.app), ref.text(for: i, fallback: c.raw), c.output, w)
                }
                verdicts = try await Judge.run(pairs: pairs, model: judgeModel, batch: 10, parallel: 6)
                var d = Data()
                for v in verdicts { d.append(try JSONEncoder().encode(v)); d.append(0x0A) }
                try d.write(to: judgeURL, options: .atomic)
            }
            // Compose.
            let tails = wItems.compactMap { wAsr[$0.id]?.tailMs }
            let cleans = wItems.compactMap { wClean[$0.id]?.totalMs }
            let e2e = wItems.compactMap { i -> Double? in
                guard let a = wAsr[i.id], let c = wClean[i.id] else { return nil }
                return a.tailMs + c.totalMs
            }
            var sw = WER.Result.zero
            var byCat: [String: WER.Result] = [:]
            for i in sItems {
                guard let r = sAsr[i.id], let ref = i.reference else { continue }
                let w = WER.compute(reference: ref, hypothesis: r.text)
                sw = sw + w
                for c in i.categories { byCat[c, default: .zero] = byCat[c, default: .zero] + w }
            }
            var ww = WER.Result.zero
            for i in wItems { if let r = wAsr[i.id], let ref = i.wisprASR { ww = ww + WER.compute(reference: ref, hypothesis: r.text) } }
            var hard: [String: Int] = [:]
            for r in Array(wClean.values) + Array(sClean.values) {
                for f in r.failures {
                    let k = String(f.prefix { $0 != ":" })
                    if k != "expectation" { hard[k, default: 0] += 1 }
                }
            }
            let expFails = sClean.values.filter { $0.failures.contains { $0.hasPrefix("expectation") } }.count
            var flags: [String: Int] = [:]
            for v in verdicts { for f in v.murmurFlags { flags[f, default: 0] += 1 } }
            out.append(StackResult(
                name: "\(asr) + \(cleaner)", asrTail: LatencySummary(tails), cleanup: LatencySummary(cleans),
                releaseToText: LatencySummary(e2e), werScripted: sItems.isEmpty ? nil : sw,
                werScriptedByCat: byCat.mapValues(\.rate), werWispr: ww.referenceWords > 0 ? ww.rate : nil,
                judge: verdicts.isEmpty ? nil : (verdicts.filter { $0.winner == "murmur" }.count, verdicts.filter { $0.winner == "tie" }.count,
                                                 verdicts.filter { $0.winner == "wispr" }.count),
                judgeFlags: flags, hardFailures: hard, expectationFails: expFails))
        }
        return out
    }

    static func print(_ rs: [StackResult], wisprLatency: LatencySummary) {
        func ms(_ s: LatencySummary) -> String { String(format: "%.0f / %.0f", s.p50 ?? 0, s.p95 ?? 0) }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "-" }
        for r in rs {
            Swift.print("\n## \(r.name)\n")
            var rows = [["measure", "value", "bar"]]
            rows.append(["ASR tail after release, p50 / p95 ms", ms(r.asrTail), ""])
            rows.append(["cleanup, p50 / p95 ms", ms(r.cleanup), ""])
            rows.append(["release to text (headless), p50 / p95 ms", ms(r.releaseToText), "500 / 1000"])
            rows.append(["Wispr's own e2e on the same items, p50 / p95 ms", ms(wisprLatency), ""])
            rows.append(["WER, scripted set (hand-checked)", pct(r.werScripted?.rate), "no worse than Wispr"])
            for c in ["whisper", "noisy", "dictionary", "code", "number", "correction"] {
                if let v = r.werScriptedByCat[c] { rows.append(["  WER \(c)", pct(v), ""]) }
            }
            rows.append(["disagreement with Wispr's recognizer, history", pct(r.werWispr), ""])
            if let j = r.judge {
                let n = Double(j.win + j.tie + j.loss)
                rows.append(["judge vs Wispr: win / tie / loss", "\(j.win) / \(j.tie) / \(j.loss)", ""])
                rows.append(["  better or tied", String(format: "%.1f%%", 100 * Double(j.win + j.tie) / max(n, 1)), "90%"])
            }
            rows.append(["judge flags on Murmur (answered, added, dropped)",
                         "\(r.judgeFlags["answered"] ?? 0), \(r.judgeFlags["added"] ?? 0), \(r.judgeFlags["dropped"] ?? 0)", "answered 0"])
            rows.append(["hard-check failures (answered, added, dropped, dictionary)",
                         "\(r.hardFailures["answered"] ?? 0), \(r.hardFailures["added"] ?? 0), \(r.hardFailures["dropped"] ?? 0), \(r.hardFailures["dictionary"] ?? 0)",
                         "answered 0"])
            rows.append(["scripted items missing an expectation", "\(r.expectationFails)", ""])
            printAligned(rows)
        }
    }
}
