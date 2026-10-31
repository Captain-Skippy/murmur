import Foundation
import MurmurCleanup
import MurmurCore

/// One cleanup of one eval item, saved for judging.
struct CleanupRow: Codable {
    var id: String
    var cleaner: String
    var asr: String
    var raw: String
    var output: String
    var usedModel: Bool
    var fellBack: String?
    var rejected: String?
    var ttftMs: Double
    var totalMs: Double
    var promptTokens: Int?
    var prefilledTokens: Int?
    var outputTokens: Int?
    var modelCalls: Int?
    var acceptedDraft: Int?
    var failures: [String]
}

enum BenchCleanup {
    static func resultsURL(set: EvalSet, cleaner: String, asr: String) -> URL {
        set.dir.appendingPathComponent("results/cleanup-\(cleaner)-\(asr)-\(CleanupPrompt.version).jsonl")
    }

    static func load(set: EvalSet, cleaner: String, asr: String) -> [String: CleanupRow] {
        guard let d = try? Data(contentsOf: resultsURL(set: set, cleaner: cleaner, asr: asr)) else { return [:] }
        var out: [String: CleanupRow] = [:]
        for l in d.split(separator: 0x0A) { if let r = try? JSONDecoder().decode(CleanupRow.self, from: Data(l)) { out[r.id] = r } }
        return out
    }

    static func appName(_ bundle: String?) -> String? {
        guard let b = bundle else { return nil }
        let known = ["com.t3tools.t3code": "T3 Code", "com.mitchellh.ghostty": "Ghostty", "ru.keepcoder.Telegram": "Telegram",
                     "app.zen-browser.zen": "Zen", "com.openai.codex": "Codex", "com.apple.Terminal": "Terminal",
                     "com.anthropic.claudefordesktop": "Claude", "com.openai.chat": "ChatGPT", "com.apple.MobileSMS": "Messages",
                     "io.element.elementx": "Element", "com.apple.Notes": "Notes", "com.apple.mail": "Mail"]
        return known[b] ?? b.split(separator: ".").last.map(String.init)
    }

    /// The raw text each item's cleanup starts from: Wispr's recognizer, or one of ours.
    static func rawInputs(set: EvalSet, items: [EvalItem], asr: String) -> [String: String] {
        if asr == "wispr" { return Dictionary(uniqueKeysWithValues: items.compactMap { i in i.wisprASR.map { (i.id, $0) } }) }
        let rows = BenchASR.loadResults(set: set, stack: asr)
        return rows.mapValues(\.text)
    }

    static func run(cleanerName: String, asr: String, set: EvalSet, items: [EvalItem]) async throws -> [CleanupRow] {
        let cleaner = try CleanerStacks.make(cleanerName)
        let (dict, snippets) = DictionaryFile.load()
        if let m = cleaner as? MLXCleaner { m.setDictionary(dict.biasingTerms) }
        let t0 = monotonicNanos()
        let mem0 = BenchASR.residentMB()
        try await cleaner.load()
        log("\(cleanerName): loaded and warm in \(Int(Double(monotonicNanos() - t0) / 1e6)) ms, +\(Int(BenchASR.residentMB() - mem0)) MB resident")
        let pipeline = CleanupPipeline(dictionary: dict, snippets: snippets)
        let raws = rawInputs(set: set, items: items, asr: asr)
        var rows: [CleanupRow] = []
        for (n, item) in items.enumerated() {
            guard let raw = raws[item.id] else { continue }
            let style = AppStyle.resolve(bundleID: item.app)
            let req = CleanupRequest(raw: raw, style: style, appName: appName(item.app),
                                     screenTerms: Array((item.screenTerms ?? []).prefix(30)))
            let first = Box()
            let s = monotonicNanos()
            let result = try await pipeline.run(req, cleaner: cleaner) { first.mark() }
            let total = Double(monotonicNanos() - s) / 1e6
            let ttft = first.at.map { Double($0 - s) / 1e6 } ?? total
            // Stats from a second, identical call would double the cost; the MLX cleaner
            // reports them on the last call instead.
            let stats = (cleaner as? MLXCleaner)?.lastStats
            let failures = HardChecks.run(raw: raw, output: result.text, dictionaryTerms: dict.biasingTerms,
                                          expectation: item.expectation).map(\.description)
            rows.append(CleanupRow(id: item.id, cleaner: cleanerName, asr: asr, raw: raw, output: result.text,
                                   usedModel: result.usedModel, fellBack: result.fellBack, rejected: result.rejected, ttftMs: ttft, totalMs: total,
                                   promptTokens: result.usedModel ? stats?.promptTokens : nil,
                                   prefilledTokens: result.usedModel ? stats?.prefilledTokens : nil,
                                   outputTokens: result.usedModel ? stats?.outputTokens : nil,
                                   modelCalls: result.usedModel ? stats?.modelCalls : nil,
                                   acceptedDraft: result.usedModel ? stats?.acceptedDraftTokens : nil, failures: failures))
            if (n + 1) % 25 == 0 { log("\(cleanerName): \(n + 1)/\(items.count)") }
        }
        let url = resultsURL(set: set, cleaner: cleanerName, asr: asr)
        try MurmurPaths.ensurePrivate(url.deletingLastPathComponent())
        var merged = load(set: set, cleaner: cleanerName, asr: asr)
        for r in rows { merged[r.id] = r }
        var out = Data()
        for r in merged.values.sorted(by: { $0.id < $1.id }) { out.append(try JSONEncoder().encode(r)); out.append(0x0A) }
        try out.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return rows
    }

    static func printTable(_ all: [(String, [CleanupRow])], asr: String) {
        print("\nCleanup on \(asr == "wispr" ? "Wispr's own recognizer text" : asr + " transcripts"); prompt \(CleanupPrompt.version). Latency in ms.")
        var rows = [["cleaner", "n", "model %", "ttft p50", "p95", "total p50", "p95", "out tok/s", "tok/call", "answered", "added", "dropped", "dict", "fell back"]]
        for (name, rs) in all {
            let model = rs.filter(\.usedModel)
            let tot = LatencySummary(rs.map(\.totalMs))
            let ttft = LatencySummary(model.map(\.ttftMs))
            let decodeMs = model.map { $0.totalMs - $0.ttftMs }.reduce(0, +)
            let outTok = model.compactMap(\.outputTokens).reduce(0, +)
            let calls = model.compactMap(\.modelCalls).reduce(0, +)
            func count(_ k: String) -> String { "\(rs.filter { $0.failures.contains { $0.hasPrefix(k) } }.count)" }
            rows.append([name, "\(rs.count)", String(format: "%.0f", 100 * Double(model.count) / Double(max(rs.count, 1))),
                         f(ttft.p50), f(ttft.p95), f(tot.p50), f(tot.p95),
                         decodeMs > 0 ? String(format: "%.0f", Double(outTok) / (decodeMs / 1000)) : "-",
                         calls > 0 ? String(format: "%.1f", Double(outTok) / Double(calls)) : "-",
                         count("answered"), count("added"), count("dropped"), count("dictionary"),
                         "\(rs.filter { $0.fellBack != nil }.count)"])
        }
        printAligned(rows)
    }

    static func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var at: UInt64?
    func mark() { lock.lock(); if at == nil { at = monotonicNanos() }; lock.unlock() }
}
