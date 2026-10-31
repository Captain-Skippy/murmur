import CryptoKit
import Foundation
import MurmurASR
import MurmurCleanup
import MurmurCore

let usage = """
    murmur: the headless side of Murmur. Private data lives in ~/Library/Application Support/Murmur.

      murmur import-wispr [--max-seconds 60]      Wispr history (read-only) -> eval set "wispr"; also its dictionary
      murmur dictionary [seed|list]               personal dictionary: seed from Wispr (if installed) and the built-in list
      murmur transcribe --stack NAME FILE.wav     one file through one recognizer
      murmur dictate [--recognizer R] [--cleaner C] [--style S] FILE.wav | --text TEXT
                                                  what the app would paste: recognize (a file), then clean;
                                                  recognizer and cleaner default to your settings
      murmur bench-asr --stacks A,B [--set wispr] [--limit N] [--max-seconds 30] [--whole] [--reuse] [--test-only]
      murmur bench-cleanup --cleaners A,B [--asr wispr|STACK] [--limit N] [--reuse] [--show]
      murmur judge --cleaner C [--asr wispr|STACK] [--limit N] [--model sonnet] [--show]
      murmur import-corpus                        Murmur's kept dictations -> eval set "murmur" with its live outputs
      murmur shadow-pair                          pair shadow captures with Wispr's history (eval set "shadow")
      murmur consensus --stacks A,B,C [--voters wispr,A,C] [--set wispr]  each system (and Wispr) vs the consensus of the others
      murmur bench --stacks asr:cleaner[,asr:cleaner]   the full table per stack (reuses saved results)
      murmur stacks                               recognizer stacks available
      murmur e2e --recognizer R --cleaner C [--set murmur] [--min-seconds 0] [--max-seconds 30] [--limit N] [--chunk-words 40]
                                              key release to text, real-time audio; --chunk-words cleans long ones in chunks
      murmur asr-vote --stacks A,B,C [--set wispr] [--name N]   word vote over saved results, A primary
      murmur relabel-ceiling [--limit N]          training targets written like the ceiling cleanup (text only, to Claude)
      murmur ceiling transcripts|cleanups|score [--set wispr] [--candidates asr:cleaner,...] [--max-seconds 60] [--model claude-opus-5-5] [--effort medium] [--redo]
                                                  the best transcript and cleanup reachable without a person, and scores against them
    """

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { options[key] = argv[i + 1]; i += 1 } else { flags.insert(key) }
            } else { positional.append(a) }
            i += 1
        }
    }
    func double(_ k: String, _ d: Double) -> Double { options[k].flatMap(Double.init) ?? d }
    func int(_ k: String) -> Int? { options[k].flatMap(Int.init) }
}

func seedDictionary() throws -> PersonalDictionary {
    var (dict, snippets) = DictionaryFile.load()
    // Wispr Flow's dictionary and snippets, when it was ever installed here.
    let wispr = (try? WisprImport.dictionary()) ?? (terms: [], snippets: [])
    dict.merge(wispr.terms)
    dict.merge(BuiltInDictionary.entries)
    for s in wispr.snippets where !snippets.contains(where: { $0.trigger.lowercased() == s.trigger.lowercased() }) {
        snippets.append(s)
    }
    try DictionaryFile.save(dict, snippets)
    return dict
}

/// Cleanup training pairs: Wispr's history minus the held-out eval items, plus, for each train-split
/// clip, a second pair whose input is our recognizer's transcript of the same audio (so the model
/// learns to fix Parakeet). Never a held-out item, never Murmur's own corpus.
func trainingPairs(asr: String) throws -> [(id: String, asr: String, pasted: String, app: String?, context: String?)] {
    let wisprSet = try? EvalSet.load("wispr")
    let eval = Set(wisprSet?.items.filter(\.isTest).map(\.id) ?? [])
    let ourRaw = wisprSet.map { BenchASR.loadResults(set: $0, stack: asr) } ?? [:]
    let trainClips = Set((wisprSet?.items.filter { !$0.isTest } ?? []).map(\.id))
    var pairs = try WisprImport.allPairs().filter { !eval.contains($0.id) }
    for p in pairs where trainClips.contains(p.id) {
        if let ours = ourRaw[p.id]?.text, !ours.isEmpty {
            pairs.append((id: p.id + "-ours", asr: ours, pasted: p.pasted, app: p.app, context: p.context))
        }
    }
    return pairs
}

/// Relabel key: SHA-1 of the escaped transcript, as train/relabel.py writes it.
func trainingKey(_ asr: String) -> String {
    String(Insecure.SHA1.hash(data: Data(CleanupPrompt.escape(asr).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
}

func main() async throws {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let cmd = argv.first else { print(usage); return }
    let args = Args(Array(argv.dropFirst()))
    switch cmd {
    case "stacks":
        print(RecognizerStacks.all.joined(separator: "\n"))

    case "import-wispr":
        let set = try WisprImport.run(maxSeconds: args.double("max-seconds", 60))
        let dict = try seedDictionary()
        let minutes = set.items.reduce(0) { $0 + $1.seconds } / 60
        var counts: [String: Int] = [:]
        for i in set.items { for c in i.categories { counts[c, default: 0] += 1 } }
        print("eval set wispr: \(set.items.count) items, \(String(format: "%.1f", minutes)) min at \(set.dir.path)")
        print("categories: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("dictionary: \(dict.entries.count) terms")

    case "dictionary":
        if args.positional.first == "seed" { _ = try seedDictionary() }
        let (dict, snippets) = DictionaryFile.load()
        print("\(dict.entries.count) terms, \(snippets.count) snippets in \(MurmurPaths.dictionary.path)")
        if args.positional.first == "list" {
            for e in dict.entries { print("\(e.term)\t\(e.sounds.joined(separator: ", "))\t\(e.source.rawValue)") }
        }

    case "transcribe":
        guard let stack = args.options["stack"], let file = args.positional.first else { throw CLIError(usage) }
        let rec = try RecognizerStacks.make(stack)
        try await rec.load()
        try await rec.setVocabulary(DictionaryFile.load().0.biasingTerms)
        let samples = try AudioFile.read16k(URL(fileURLWithPath: file))
        let t = monotonicNanos()
        let text = try await rec.transcribe(samples)
        print(text)
        log(String(format: "%.0f ms for %.1f s of audio", Double(monotonicNanos() - t) / 1e6, Double(samples.count) / 16_000))

    case "dictate":
        let settings = MurmurSettings.load()
        var raw = args.options["text"] ?? ""
        if raw.isEmpty {
            guard let file = args.positional.first else { throw CLIError(usage) }
            let rec = try RecognizerStacks.make(args.options["recognizer"] ?? settings.recognizer)
            var t = monotonicNanos()
            try await rec.load()
            log(String(format: "recognizer %@ loaded in %.1f s", rec.name, Double(monotonicNanos() - t) / 1e9))
            try await rec.setVocabulary(DictionaryFile.load().0.biasingTerms)
            let samples = try AudioFile.read16k(URL(fileURLWithPath: file))
            t = monotonicNanos()
            raw = try await rec.transcribe(samples)
            log(String(format: "transcript (%.0f ms for %.1f s of audio): %@", Double(monotonicNanos() - t) / 1e6,
                       Double(samples.count) / 16_000, raw))
        }
        let (dict, snippets) = DictionaryFile.load()
        let cleaner = try CleanerStacks.make(args.options["cleaner"] ?? settings.cleaner)
        var t = monotonicNanos()
        try await cleaner.load()
        log(String(format: "cleaner %@ loaded in %.1f s", cleaner.name, Double(monotonicNanos() - t) / 1e9))
        let style = args.options["style"].flatMap(AppStyle.init(rawValue:)) ?? .neutral
        t = monotonicNanos()
        let r = try await CleanupPipeline(dictionary: dict, snippets: snippets)
            .run(CleanupRequest(raw: raw, style: style), cleaner: cleaner) {}
        log(String(format: "cleaned in %.0f ms%@", Double(monotonicNanos() - t) / 1e6,
                   r.fellBack.map { " (fell back to the transcript: \($0))" } ?? ""))
        print(r.text)

    case "bench-asr":
        let setName = args.options["set"] ?? "wispr"
        let set = try EvalSet.load(setName)
        let maxSec = args.double("max-seconds", 30)
        var items = set.items.filter { $0.seconds <= maxSec && $0.excluded == nil && (!args.flags.contains("test-only") || $0.isTest) }
        if let n = args.int("limit"), n < items.count {
            // Spread the sample across the whole history, not just the oldest items.
            let step = Double(items.count) / Double(n)
            items = (0..<n).map { items[Int(Double($0) * step)] }
        }
        let stacks = (args.options["stacks"] ?? "parakeet-v2").split(separator: ",").map(String.init)
        let terms = DictionaryFile.load().0.biasingTerms
        var sums: [BenchASR.Summary] = []
        for stack in stacks {
            var rows = args.flags.contains("reuse") ? BenchASR.loadResults(set: set, stack: stack) : [:]
            let missing = items.filter { rows[$0.id] == nil }
            if !missing.isEmpty {
                for r in try await BenchASR.run(stack: stack, set: set, items: missing, vocabulary: terms, whole: args.flags.contains("whole")) {
                    rows[r.id] = r
                }
            }
            sums.append(BenchASR.summarize(stack: stack, items: items, rows: rows, terms: terms))
        }
        let cats = ["under5s", "5to15s", "15to30s", "over30s", "quiet", "whisper", "noisy", "dictionary", "code", "number"].filter { c in items.contains { $0.categories.contains(c) } }
        let refKind = items.allSatisfy { $0.reference != nil } ? "WER against hand-checked references"
            : "WER against Wispr's own recognizer output (agreement, not true WER)"
        BenchASR.printTable(sums, categories: cats, refKind: refKind)
        let wisprLat = items.compactMap(\.wisprLatencyMs)
        if !wisprLat.isEmpty {
            let s = LatencySummary(wisprLat)
            print(String(format: "\nWispr Flow e2e latency on the same items (its own log): p50 %.0f ms, p95 %.0f ms", s.p50 ?? 0, s.p95 ?? 0))
        }

    case "bench-cleanup":
        let set = try EvalSet.load(args.options["set"] ?? "wispr")
        let asr = args.options["asr"] ?? "wispr"
        var items = set.items.filter {
            $0.seconds <= args.double("max-seconds", 30) && $0.seconds >= args.double("min-seconds", 0) && $0.excluded == nil && $0.isTest
        }
        if let n = args.int("limit"), n < items.count {
            let step = Double(items.count) / Double(n)
            items = (0..<n).map { items[Int(Double($0) * step)] }
        }
        var all: [(String, [CleanupRow])] = []
        for c in (args.options["cleaners"] ?? "none").split(separator: ",").map(String.init) {
            var rows = args.flags.contains("reuse") ? BenchCleanup.load(set: set, cleaner: c, asr: asr) : [:]
            let missing = items.filter { rows[$0.id] == nil }
            if !missing.isEmpty { for r in try await BenchCleanup.run(cleanerName: c, asr: asr, set: set, items: missing) { rows[r.id] = r } }
            all.append((c, items.compactMap { rows[$0.id] }))
        }
        BenchCleanup.printTable(all, asr: asr)
        if args.flags.contains("show") {
            for (name, rs) in all {
                for r in rs.prefix(args.int("show-n") ?? 8) {
                    print("\n[\(name)] RAW: \(r.raw)\n    OUT: \(r.output)" + (r.failures.isEmpty ? "" : "\n    FAIL: \(r.failures.joined(separator: "; "))")
                          + (r.rejected.map { "\n    REJECTED (\(r.fellBack ?? "")): \($0)" } ?? ""))
                }
            }
        }

    case "judge":
        let set = try EvalSet.load(args.options["set"] ?? "wispr")
        let asr = args.options["asr"] ?? "wispr"
        guard let cleaner = args.options["cleaner"] else { throw CLIError(usage) }
        let rows = BenchCleanup.load(set: set, cleaner: cleaner, asr: asr)
        var items = set.items.filter { rows[$0.id] != nil && $0.wisprText != nil && $0.isTest }
        if let n = args.int("limit"), n < items.count {
            let step = Double(items.count) / Double(n)
            items = (0..<n).map { items[Int(Double($0) * step)] }
        }
        // "Spoken": with Wispr's own text as input, that text; end to end, the word-level consensus
        // of four recognizers (Wispr's included), so neither side's recognizer is taken as truth.
        let spokenRef = Judge.SpokenReference(set: set)
        func spoken(_ i: EvalItem) -> String {
            asr == "wispr" ? (i.wisprASR ?? rows[i.id]!.raw) : spokenRef.text(for: i, fallback: rows[i.id]!.raw)
        }
        let pairs = items.map { i in (id: i.id, app: BenchCleanup.appName(i.app), spoken: spoken(i),
                                      murmur: rows[i.id]!.output, wispr: i.wisprText!) }
        let verdicts = try await Judge.run(pairs: pairs, model: args.options["model"] ?? "sonnet",
                                           batch: args.int("batch") ?? 10, parallel: args.int("parallel") ?? 4,
                                           flip: args.flags.contains("flip"))
        let suffix = args.flags.contains("flip") ? "-flip" : ""
        let url = set.dir.appendingPathComponent("results/judge-\(cleaner)-\(asr)-\(CleanupPrompt.version)\(suffix).jsonl")
        var out = Data()
        for v in verdicts { out.append(try JSONEncoder().encode(v)); out.append(0x0A) }
        try out.write(to: url, options: .atomic)
        print("\nBlind pairwise judge (\(args.options["model"] ?? "sonnet")), \(cleaner) on \(asr) text vs Wispr's pasted text:")
        print(Judge.summarize(verdicts))
        if args.flags.contains("show") {
            let byId = Dictionary(uniqueKeysWithValues: pairs.map { ($0.id, $0) })
            for v in verdicts where v.winner == "wispr" || !v.murmurFlags.isEmpty {
                guard let p = byId[v.id] else { continue }
                print("\n- \(v.winner) \(v.murmurFlags) \(v.reason)\n  SPOKEN: \(p.spoken)\n  MURMUR: \(p.murmur)\n  WISPR:  \(p.wispr)")
            }
        }

    case "export-training":
        // Chat-format training data from Wispr pairs NOT in the eval set, plus synthetic cases.
        // Private: written under Murmur's support folder, never committed.
        let eval = Set((try? EvalSet.load("wispr"))?.items.filter(\.isTest).map(\.id) ?? [])
        let dict = DictionaryFile.load().0.biasingTerms
        let system = CleanupPrompt.tunedSystem(dictionary: dict)
        var rows: [[String: Any]] = []
        var skipped = 0
        // Relabeled targets (train/relabel.py, or `relabel-ceiling` with --relabel-file), keyed by
        // SHA-1 of the escaped transcript.
        var relabel: [String: String] = [:]
        // Several files, comma separated: the first that has a transcript wins.
        let relabelFiles = (args.options["relabel-file"] ?? (args.flags.contains("relabel") ? "relabel.jsonl" : ""))
            .split(separator: ",").map(String.init)
        for f in relabelFiles.reversed() {
            guard let d = try? String(contentsOf: MurmurPaths.support.appendingPathComponent("train/\(f)"), encoding: .utf8) else {
                throw CLIError("no relabel file train/\(f)")
            }
            for l in d.split(separator: "\n") {
                if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: String], let k = o["id"], let v = o["output"] ?? o["text"] { relabel[k] = v }
            }
        }
        var relabeled = 0
        // Chunk-shaped cases (train/chunks.py), keyed like relabel: each long transcript's pieces
        // as `ChunkedCleanup` cleans them, added beside the whole transcript.
        var chunks: [String: [(raw: String, output: String)]] = [:]
        if let f = args.options["chunks"] {
            guard let d = try? String(contentsOf: MurmurPaths.support.appendingPathComponent("train/\(f)"), encoding: .utf8) else {
                throw CLIError("no chunks file train/\(f)")
            }
            for l in d.split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let k = o["id"] as? String,
                      let cs = o["chunks"] as? [[String: String]] else { continue }
                chunks[k] = cs.compactMap { c in c["raw"].flatMap { r in c["output"].map { (r, $0) } } }
            }
        }
        var chunkRows = 0
        let pairs = try trainingPairs(asr: args.options["asr"] ?? "parakeet-unified")
        for p in pairs {
            var target = p.pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = relabel[trainingKey(p.asr)] { target = r.trimmingCharacters(in: .whitespacesAndNewlines); relabeled += 1 }
            // Wispr sometimes pasted HTML lists; never teach HTML.
            if target.contains("<li>") || target.contains("<ul>") || target.contains("<ol>") { skipped += 1; continue }
            // Skip empty, very long, and rewrites that are not formatting (Wispr's own mistakes or commands).
            let ratio = Double(target.count) / Double(max(p.asr.count, 1))
            if target.isEmpty || p.asr.count > 2500 || ratio > 1.6 || ratio < 0.3 { skipped += 1; continue }
            // Targets that still carry fillers teach the model to keep them.
            if args.flags.contains("drop-filler-targets"),
               WER.normalize(target, dropFillers: false).contains(where: { ["um", "uh", "umm", "uhh"].contains($0) }) {
                skipped += 1; continue
            }
            let req = CleanupRequest(raw: p.asr, style: AppStyle.resolve(bundleID: p.app), appName: BenchCleanup.appName(p.app),
                                     screenTerms: Array((WisprImport.screenTerms(p.context) ?? []).prefix(30)))
            rows.append(["messages": [["role": "system", "content": system], ["role": "user", "content": CleanupPrompt.user(req)],
                                      ["role": "assistant", "content": target]]])
            for c in chunks[trainingKey(p.asr)] ?? [] {
                var r = req
                r.raw = c.raw
                rows.append(["messages": [["role": "system", "content": system], ["role": "user", "content": CleanupPrompt.user(r)],
                                          ["role": "assistant", "content": c.output]]])
                chunkRows += 1
            }
        }
        if let synth = args.options["synthetic"] {
            let weight = args.int("synthetic-weight") ?? 1
            for line in try String(contentsOfFile: synth, encoding: .utf8).split(separator: "\n") {
                guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                      let raw = o["raw"], let out = o["output"] else { continue }
                let style = AppStyle(rawValue: o["style"] ?? "neutral") ?? .neutral
                let req = CleanupRequest(raw: raw, style: style, appName: o["app"])
                let row: [String: Any] = ["messages": [["role": "system", "content": system], ["role": "user", "content": CleanupPrompt.user(req)],
                                                       ["role": "assistant", "content": out]]]
                rows += Array(repeating: row, count: weight)
            }
        }
        var g = SystemRandomNumberGenerator()
        rows.shuffle(using: &g)
        let dir = MurmurPaths.support.appendingPathComponent("train/data")
        try MurmurPaths.ensurePrivate(dir)
        let nValid = max(20, rows.count / 20)
        for (name, part) in [("valid", rows.prefix(nValid)), ("train", rows.dropFirst(nValid))] {
            var d = Data()
            for r in part { d.append(try JSONSerialization.data(withJSONObject: r, options: [.withoutEscapingSlashes])); d.append(0x0A) }
            try d.write(to: dir.appendingPathComponent("\(name).jsonl"), options: .atomic)
        }
        print("training data: \(rows.count - nValid) train, \(nValid) valid (\(skipped) skipped, \(relabeled) relabeled, \(chunkRows) chunk cases, \(eval.count) eval items excluded) in \(dir.path)")

    case "bench":
        // STACKS: "asr:cleaner,asr:cleaner"
        let stacks = (args.options["stacks"] ?? "parakeet-unified:none").split(separator: ",").map { pair -> (asr: String, cleaner: String) in
            let p = pair.split(separator: ":").map(String.init)
            return (p[0], p.count > 1 ? p[1] : "none")
        }
        let results = try await Bench.run(stacks: stacks, judgeModel: args.options["model"] ?? "sonnet")
        let wispr = try EvalSet.load("wispr")
        Bench.print(results, wisprLatency: LatencySummary(wispr.items.filter { $0.seconds <= 30 }.compactMap(\.wisprLatencyMs)))

    case "shadow-pair":
        // Shadow captures matched to Wispr's entries -> eval set "shadow" plus Murmur's live outputs.
        let entries = ShadowEntry.all()
        guard let first = entries.first else { print("no shadow captures yet (turn on shadowMode in settings)"); return }
        let wispr = try WisprImport.rows(since: first.startedAt.addingTimeInterval(-60))
        let byId = Dictionary(uniqueKeysWithValues: wispr.map { ($0.id, $0) })
        var set = (try? EvalSet.load("shadow")) ?? EvalSet(name: "shadow", dir: EvalSet.url("shadow"), items: [])
        try MurmurPaths.ensurePrivate(set.dir.appendingPathComponent("audio"))
        var live: [CleanupRow] = []
        var paired = 0
        for e in entries {
            guard let wid = ShadowEntry.match(e, wisprTimes: wispr.map { ($0.id, $0.at) }), let w = byId[wid] else { continue }
            let rel = "audio/\(e.id).wav"
            let dst = set.dir.appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.copyItem(at: MurmurPaths.shadow.appendingPathComponent("\(e.id).wav"), to: dst)
            }
            var item = EvalItem(id: e.id, audio: rel, seconds: e.seconds, categories: [WisprImport.bucket(e.seconds)])
            item.app = e.app ?? w.app
            item.wisprASR = w.asr
            item.wisprPasted = w.pasted
            item.recordedAt = e.startedAt
            set.items.removeAll { $0.id == e.id }
            set.items.append(item)
            live.append(CleanupRow(id: e.id, cleaner: "live", asr: "live", raw: e.raw, output: e.output, usedModel: true,
                                   fellBack: nil, rejected: nil, ttftMs: 0, totalMs: e.cleanupMs ?? 0, promptTokens: nil,
                                   prefilledTokens: nil, outputTokens: nil, modelCalls: nil, acceptedDraft: nil, failures: []))
            paired += 1
        }
        try set.save()
        let url = BenchCleanup.resultsURL(set: set, cleaner: "live", asr: "live")
        try MurmurPaths.ensurePrivate(url.deletingLastPathComponent())
        var d = Data()
        for r in live { d.append(try JSONEncoder().encode(r)); d.append(0x0A) }
        try d.write(to: url, options: .atomic)
        print("\(entries.count) shadow captures, \(paired) paired with Wispr; eval set shadow has \(set.items.count) items.")
        print("Judge them: murmur judge --set shadow --cleaner live --asr live")

    case "consensus":
        // Rank systems (Wispr included) against the word-level consensus of the others.
        let set = try EvalSet.load(args.options["set"] ?? "wispr")
        let stacks = (args.options["stacks"] ?? "").split(separator: ",").map(String.init)
        let items = set.items.filter { $0.seconds <= args.double("max-seconds", 60) }
        let results = stacks.map { BenchASR.loadResults(set: set, stack: $0) }
        let systems = ["wispr"] + stacks
        let hyps: [[String?]] = items.map { item in [item.wisprASR] + results.map { $0[item.id]?.text } }
        let voters = args.options["voters"].map { Set($0.split(separator: ",").map(String.init)) }
        let r = Consensus.leaveOneOut(systems: systems, hyps: hyps, voters: voters)
        let who = voters.map { $0.sorted().joined(separator: ", ") } ?? "all other systems"
        print("\nEstimated WER: each system against the word-level consensus of the voters other than itself (\(who); \(items.count) items).")
        print("Correlated systems (same model family) can outvote the truth; hand-checked references settle it.")
        var rows = [["system", "WER", "sub", "del", "ins", "ref words"]]
        for name in systems.sorted(by: { r[$0]!.rate < r[$1]!.rate }) {
            let x = r[name]!
            rows.append([name, String(format: "%.2f%%", x.rate * 100), "\(x.substitutions)", "\(x.deletions)", "\(x.insertions)", "\(x.referenceWords)"])
        }
        printAligned(rows)

    case "ceiling":
        try await ceilingCommand(args)

    case "e2e":
        let set = try EvalSet.load(args.options["set"] ?? "murmur")
        var items = set.items.filter {
            $0.seconds <= args.double("max-seconds", 30) && $0.seconds >= args.double("min-seconds", 0) && $0.excluded == nil && $0.isTest
        }
        if let n = args.int("limit"), n < items.count {
            let step = Double(items.count) / Double(n)
            items = (0..<n).map { items[Int(Double($0) * step)] }
        }
        try await E2E.run(set: set, items: items, recognizer: args.options["recognizer"] ?? "parakeet-unified",
                          cleaner: args.options["cleaner"] ?? MurmurSettings.load().cleaner, speed: args.double("speed", 1),
                          chunkWords: args.int("chunk-words"))

    case "asr-vote":
        // A word vote over saved recognizer results (the first is primary), saved as its own stack
        // so bench-cleanup and ceiling score can use it. Tail latency: the slowest voter's tail.
        let set = try EvalSet.load(args.options["set"] ?? "wispr")
        let stacks = (args.options["stacks"] ?? "").split(separator: ",").map(String.init)
        guard stacks.count >= 3 else { throw CLIError("asr-vote needs three or more --stacks") }
        let name = args.options["name"] ?? "vote-" + stacks.joined(separator: "+")
        let results = stacks.map { BenchASR.loadResults(set: set, stack: $0) }
        var rows: [ASRResultRow] = []
        for i in set.items {
            let hs = results.compactMap { $0[i.id] }
            guard hs.count == stacks.count else { continue }
            rows.append(ASRResultRow(id: i.id, stack: name, text: TranscriptVote.vote(hs.map(\.text)), tailMs: hs.map(\.tailMs).max() ?? 0,
                                     wholeMs: nil, wholeText: nil, segments: hs[0].segments, maxSegmentRTF: hs.map(\.maxSegmentRTF).max() ?? 0))
        }
        try Ceiling.save(rows, BenchASR.resultsURL(set: set, stack: name))
        let changed = rows.filter { $0.text != results[0][$0.id]!.text }.count
        print("\(name): \(rows.count) items, \(changed) differ from \(stacks[0])")

    case "relabel-ceiling":
        // Training targets written the way the ceiling cleanup is (Claude, text only), so the tuned
        // model learns the reference's rules rather than Wispr's habits. Held-out items never go in.
        let out = MurmurPaths.support.appendingPathComponent("train/relabel-ceiling.jsonl")
        var done = Ceiling.load(Ceiling.Cleanup.self, out)
        let have = Set(done.map(\.id))
        var seen = Set<String>()
        var cases: [Ceiling.TrainingCase] = []
        for p in try trainingPairs(asr: args.options["asr"] ?? "parakeet-unified") {
            let k = trainingKey(p.asr)
            guard !have.contains(k), !seen.contains(k), p.asr.count <= 2500 else { continue }
            seen.insert(k)
            cases.append(.init(id: k, raw: p.asr, app: p.app, screenTerms: WisprImport.screenTerms(p.context)))
        }
        if let n = args.int("limit") { cases = Array(cases.prefix(n)) }
        log("relabel-ceiling: \(cases.count) to write, \(done.count) done")
        done += try await Ceiling.relabel(cases, dictionary: DictionaryFile.load().0.biasingTerms,
                                          model: args.options["model"] ?? "claude-opus-5-5", effort: args.options["effort"] ?? "medium",
                                          batch: args.int("batch") ?? 12, parallel: args.int("parallel") ?? 6) { rows in
            try? Ceiling.save(rows, out)
        }
        try Ceiling.save(done, out)
        print("relabel-ceiling: \(done.count) targets in \(out.path)")

    case "import-corpus":
        // Every kept dictation becomes a scored item; what Murmur heard and inserted live are saved
        // as the "live" recognizer and cleanup results.
        var set = (try? EvalSet.load("murmur")) ?? EvalSet(name: "murmur", dir: EvalSet.url("murmur"), items: [])
        try MurmurPaths.ensurePrivate(set.dir.appendingPathComponent("audio"))
        try MurmurPaths.ensurePrivate(set.dir.appendingPathComponent("results"))
        let corpus = CorpusStore()
        var asr: [ASRResultRow] = [], live: [CleanupRow] = []
        for r in corpus.all() where !r.raw.isEmpty {
            let id = r.id.uuidString
            let rel = "audio/\(id).wav"
            let dst = set.dir.appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.copyItem(at: corpus.dir.appendingPathComponent("\(HistoryStore.dayFormat.string(from: r.at))/\(id).wav"), to: dst)
            }
            var item = EvalItem(id: id, audio: rel, seconds: r.seconds, categories: [WisprImport.bucket(r.seconds)])
            item.app = r.app
            item.recordedAt = r.at
            item.split = "test"
            item.textBefore = r.before.isEmpty ? nil : String(r.before.suffix(400))
            set.items.removeAll { $0.id == id }
            set.items.append(item)
            asr.append(ASRResultRow(id: id, stack: "live", text: r.raw, tailMs: 0, wholeMs: nil, wholeText: nil, segments: 1, maxSegmentRTF: 0))
            live.append(CleanupRow(id: id, cleaner: "live", asr: "live", raw: r.raw, output: r.inserted, usedModel: true, fellBack: nil,
                                   rejected: nil, ttftMs: 0, totalMs: 0, promptTokens: nil, prefilledTokens: nil, outputTokens: nil,
                                   modelCalls: nil, acceptedDraft: nil, failures: []))
        }
        try set.save()
        try Ceiling.save(asr, set.dir.appendingPathComponent("results/asr-live.jsonl"))
        try Ceiling.save(live, BenchCleanup.resultsURL(set: set, cleaner: "live", asr: "live"))
        print("eval set murmur: \(set.items.count) items, \(String(format: "%.1f", set.items.reduce(0) { $0 + $1.seconds } / 60)) min")

    default:
        print(usage)
    }
}

func ceilingCommand(_ args: Args) async throws {
    let set = try EvalSet.load(args.options["set"] ?? "wispr")
    let model = args.options["model"] ?? "claude-opus-5-5", effort = args.options["effort"] ?? "medium"
    let batch = args.int("batch") ?? 8, parallel = args.int("parallel") ?? 4
    let items = set.items.filter { $0.seconds <= args.double("max-seconds", 60) && $0.excluded == nil }
    let dictionary = DictionaryFile.load().0.biasingTerms
    let transcriptURL = Ceiling.url(set, "transcripts"), cleanupURL = Ceiling.url(set, "cleanups")
    var transcripts = args.flags.contains("redo") && args.positional.first == "transcripts" ? [] : Ceiling.load(Ceiling.Transcript.self, transcriptURL)
    let spoken = { Dictionary(transcripts.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a }) }

    switch args.positional.first {
    case "transcripts":
        let voters = args.options["voters"].map { $0.split(separator: ",").map(String.init) } ?? Ceiling.defaultVoters
        let have = Set(transcripts.map(\.id))
        transcripts += try await Ceiling.buildTranscripts(set: set, items: items.filter { !have.contains($0.id) }, voters: voters,
                                                          dictionary: dictionary, model: model, effort: effort, batch: batch, parallel: parallel)
        try Ceiling.save(transcripts, transcriptURL)
        // Also as a recognizer result, so `bench-cleanup --asr ceiling` cleans the ceiling transcript.
        try Ceiling.save(transcripts.map { ASRResultRow(id: $0.id, stack: "ceiling", text: $0.text, tailMs: 0, wholeMs: nil, wholeText: nil,
                                                        segments: 1, maxSegmentRTF: 0) },
                         set.dir.appendingPathComponent("results/asr-ceiling.jsonl"))
        let by = Dictionary(grouping: transcripts, by: \.settledBy).mapValues(\.count)
        print("ceiling transcripts for \(set.name): \(transcripts.count) (\(by.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))")

    case "cleanups":
        // Scored items only: the held-out split of the history set; every scripted item.
        let scored = items.filter(\.isTest)
        var rows = args.flags.contains("redo") ? [] : Ceiling.load(Ceiling.Cleanup.self, cleanupURL)
        let have = Set(rows.map(\.id))
        rows += try await Ceiling.buildCleanups(set: set, items: scored.filter { !have.contains($0.id) }, transcripts: spoken(),
                                                dictionary: dictionary, model: model, effort: effort, batch: batch, parallel: parallel)
        try Ceiling.save(rows, cleanupURL)
        print("ceiling cleanups for \(set.name): \(rows.count)")

    case "score":
        let ref = spoken()
        let scoredItems = items.filter { ref[$0.id] != nil }
        // Recognition: every saved recognizer (and Wispr's) against the ceiling transcript; on the
        // scripted set also against the hand-checked reference, which tests the ceiling itself.
        let resultsDir = set.dir.appendingPathComponent("results")
        let stacks = ((try? FileManager.default.contentsOfDirectory(atPath: resultsDir.path)) ?? [])
            .filter { $0.hasPrefix("asr-") && $0.hasSuffix(".jsonl") }.map { String($0.dropFirst(4).dropLast(6)) }.sorted()
        let voters = Set(Ceiling.defaultVoters)
        var asrRows = [["recognizer", "WER vs ceiling", "items"] + (set.name == "scripted" ? ["WER vs hand reference"] : [])]
        var systems: [(String, [String: String])] = stacks.map { s in (s, BenchASR.loadResults(set: set, stack: s).mapValues(\.text)) }
        if set.items.contains(where: { $0.wisprASR != nil }) {
            systems.append(("wispr", Dictionary(set.items.compactMap { i in i.wisprASR.map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })))
        }
        var werRows: [(Double, [String])] = []
        for (name, texts) in systems {
            var vsCeil = WER.Result.zero, vsHand = WER.Result.zero, n = 0
            for i in scoredItems {
                guard let h = texts[i.id] else { continue }
                n += 1
                if name != "ceiling" { vsCeil = vsCeil + WER.compute(reference: ref[i.id]!, hypothesis: h) }
                if let r = i.reference { vsHand = vsHand + WER.compute(reference: r, hypothesis: h) }
            }
            guard n > 0 else { continue }
            let label = name + (voters.contains(name) ? " *" : "")
            var row = [label, name == "ceiling" ? "-" : String(format: "%.2f%%", vsCeil.rate * 100), "\(n)"]
            if set.name == "scripted" { row.append(String(format: "%.2f%%", vsHand.rate * 100)) }
            werRows.append((name == "ceiling" ? -1 : vsCeil.rate, row))
        }
        asrRows += werRows.sorted { $0.0 < $1.0 }.map(\.1)
        print("\nRecognition against the ceiling transcript (\(set.name), \(scoredItems.count) items up to \(Int(args.double("max-seconds", 60))) s).")
        print("* voted on the ceiling, so its own WER is flattered.")
        printAligned(asrRows)

        // Cleanup: each candidate graded by Claude against the ceiling cleanup (the hand-written
        // expected text on the scripted set, where the ceiling cleanup itself is a candidate).
        let cleanups = Dictionary(Ceiling.load(Ceiling.Cleanup.self, cleanupURL).map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        var gold: [String: String] = cleanups
        var candidates: [(String, [String: String])] = []
        let liveCleaner = args.options["cleaner"] ?? MurmurSettings.load().cleaner
        if set.name == "scripted" {
            gold = Dictionary(set.items.compactMap { i in i.expectedText.map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })
            candidates.append(("ceiling cleanup", cleanups))
        } else {
            candidates.append(("Wispr", Dictionary(set.items.compactMap { i in i.wisprText.map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })))
        }
        candidates.append(("Murmur", BenchCleanup.load(set: set, cleaner: liveCleaner, asr: "parakeet-unified").mapValues(\.output)))
        candidates.append(("Murmur live", BenchCleanup.load(set: set, cleaner: "live", asr: "live").mapValues(\.output)))
        candidates.append(("Murmur cleanup on ceiling transcript", BenchCleanup.load(set: set, cleaner: liveCleaner, asr: "ceiling").mapValues(\.output)))
        // More stacks to compare, "asr:cleaner" (saved bench-cleanup results).
        for c in (args.options["candidates"] ?? "").split(separator: ",").map(String.init) {
            let p = c.split(separator: ":", maxSplits: 1).map(String.init)
            guard p.count == 2 else { throw CLIError("candidate \(c): want asr:cleaner") }
            candidates.append((c, BenchCleanup.load(set: set, cleaner: p[1], asr: p[0]).mapValues(\.output)))
        }
        // Grades are reused for any item whose text some earlier grading already saw (paired comparison).
        var cache = args.flags.contains("redo") ? [:] : Ceiling.gradeCache(set)
        var table = [["candidate", "at reference quality", "items", "text WER vs ref"] + Ceiling.categories + ["vs Murmur: changed", "fixed", "broke"]]
        var baseline: [String: Ceiling.Grade] = [:]
        for (name, outs) in candidates {
            let cases = scoredItems.filter(\.isTest).compactMap { i -> (id: String, spoken: String, ref: String, out: String)? in
                guard let g = gold[i.id], let o = outs[i.id] else { return nil }
                return (i.id, ref[i.id]!, g, o)
            }
            guard !cases.isEmpty else { log("ceiling: no outputs for \(name); skipped"); continue }
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "--")
            let gradeURL = Ceiling.url(set, "grades-\(slug)")
            let byId = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var grades = args.flags.contains("redo") ? [] : Ceiling.load(Ceiling.Grade.self, gradeURL).filter { byId[$0.id] != nil }
            // Grades saved before `out` existed belong to this candidate's current text.
            for k in grades.indices where grades[k].out == nil { grades[k].out = byId[grades[k].id]!.out }
            // A saved grade of different text is stale.
            grades.removeAll { $0.out != byId[$0.id]!.out }
            for c in cases where !grades.contains(where: { $0.id == c.id }) {
                if var g = cache[c.id + "\u{0}" + c.out] { g.candidate = name; grades.append(g) }
            }
            let have = Set(grades.map(\.id))
            let todo = cases.filter { !have.contains($0.id) }
            if !todo.isEmpty { log("ceiling: \(name): grading \(todo.count) new texts, \(cases.count - todo.count) reused") }
            grades += try await Ceiling.grade(candidate: name, cases: todo, model: model, effort: effort, batch: batch, parallel: parallel)
            try Ceiling.save(grades, gradeURL)
            for g in grades where cache[g.id + "\u{0}" + (g.out ?? "")] == nil { cache[g.id + "\u{0}" + (g.out ?? "")] = g }
            let textWER = cases.reduce(WER.Result.zero) { $0 + WER.compute(reference: $1.ref, hypothesis: $1.out) }
            var row = [name] + Ceiling.summary(grades, textWER: textWER)
            if name == "Murmur" { baseline = Dictionary(grades.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
            let paired = grades.filter { baseline[$0.id] != nil }
            row += ["\(paired.filter { $0.out != baseline[$0.id]!.out }.count)",
                    "\(paired.filter { $0.errors.isEmpty && !baseline[$0.id]!.errors.isEmpty }.count)",
                    "\(paired.filter { !$0.errors.isEmpty && baseline[$0.id]!.errors.isEmpty }.count)"]
            table.append(row)
        }
        print("\nCleanup graded by \(model) (\(effort)) against " + (set.name == "scripted" ? "the hand-written expected text." : "the ceiling cleanup (held-out items)."))
        print("Changed, fixed and broke count items against the Murmur row; an unchanged text keeps its grade.")
        printAligned(table)

    default:
        print(usage)
    }
}

do {
    try await main()
} catch {
    log("error: \(error)")
    exit(1)
}
