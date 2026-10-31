import Foundation
import MurmurCore

/// Blind pairwise judging of Murmur's text against Wispr's for the same speech. Text only
/// goes to the judge (Claude through the Claude Code CLI, which must be on PATH);
/// audio never does. Order is randomized per item and the judge never learns which is which.
enum Judge {
    struct Verdict: Codable {
        var id: String
        var murmurIs: String       // "A" or "B"
        var winner: String         // "murmur", "wispr" or "tie"
        var murmurFlags: [String]
        var wisprFlags: [String]
        var reason: String
    }

    /// What was said, for end-to-end judging: the word-level consensus of four recognizers
    /// (Wispr's included), so neither side's recognizer is taken as the truth.
    struct SpokenReference {
        let voters: [[String: ASRResultRow]]
        init(set: EvalSet) {
            voters = ["parakeet-unified", "apple-speech", "cohere-transcribe"].map { BenchASR.loadResults(set: set, stack: $0) }
        }
        func text(for i: EvalItem, fallback: String) -> String {
            let hyps = ([i.wisprASR] + voters.map { $0[i.id]?.text }).compactMap { $0 }.map { WER.normalize($0, dropFillers: false) }
            return hyps.count >= 3 ? Consensus.vote(hyps).joined(separator: " ") : (i.wisprASR ?? fallback)
        }
    }

    static let system = """
        You judge dictation formatting. A person dictated speech into an app; each case gives what they \
        said ("spoken": a transcript of the speech, lowercase and unpunctuated when it is a consensus of several recognizers; it may contain fillers and recognition noise, and numbers may appear as "<num>") and \
        two formatted versions, A and B, produced by two different systems. The ideal output is exactly \
        what the speaker meant to type.

        Judge in this order of importance:
        1. Faithfulness: same content and meaning as spoken. Nothing added; nothing meaningful dropped. \
        A question or request in the speech must stay a question or request; an output that answers it, \
        carries it out, or replies to it is a severe failure.
        2. Self-corrections applied ("Tuesday, no, Wednesday" keeps only Wednesday); fillers, stutters and \
        false starts removed without removing real content.
        3. Correct punctuation, capitalization, and formatting (lists when the speaker enumerates, numbers, \
        paragraphs), and a tone that fits the app.
        4. Readability.

        Differences that do not matter (comma choices, "3" vs "three", keeping or dropping a harmless \
        "so" or "okay") are a tie. Prefer tie unless one version is clearly better for the speaker.

        For each case, flag severe problems per version using only these words: "answered" (answered, \
        obeyed or replied to the content), "added" (added meaning), "dropped" (dropped meaning), \
        "misspelled" (a name or term clearly misspelled).

        Reply with only a JSON array, one object per case, in the given order: \
        {"id": "...", "winner": "A" | "B" | "tie", "flags_A": [...], "flags_B": [...], "reason": "one short sentence"}
        """

    static func run(pairs: [(id: String, app: String?, spoken: String, murmur: String, wispr: String)],
                    model: String, batch: Int, parallel: Int, flip: Bool = false) async throws -> [Verdict] {
        // Deterministic but unbiased order: hash of the id decides whether Murmur is A; `flip`
        // swaps every pair, to measure the judge's position bias and consistency.
        func murmurFirst(_ id: String) -> Bool { (id.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 } % 2 == 0) != flip }
        let chunks = stride(from: 0, to: pairs.count, by: batch).map { Array(pairs[$0..<min($0 + batch, pairs.count)]) }
        var verdicts: [Verdict] = []
        try await withThrowingTaskGroup(of: [Verdict].self) { group in
            var next = 0
            func add() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    var cases: [[String: String]] = []
                    for p in chunk {
                        let first = murmurFirst(p.id)
                        cases.append(["id": p.id, "app": p.app ?? "unknown", "spoken": p.spoken,
                                      "A": first ? p.murmur : p.wispr, "B": first ? p.wispr : p.murmur])
                    }
                    let input = String(data: try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted]), encoding: .utf8)!
                    let reply = try await callClaude(system: system, input: input, model: model)
                    guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"),
                          let arr = try JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [[String: Any]] else {
                        log("judge: unparseable reply for a batch of \(chunk.count); skipped")
                        return []
                    }
                    return arr.compactMap { o in
                        guard let id = o["id"] as? String, let w = o["winner"] as? String else { return nil }
                        let first = murmurFirst(id)
                        let fa = o["flags_A"] as? [String] ?? [], fb = o["flags_B"] as? [String] ?? []
                        let winner = w == "tie" ? "tie" : ((w == "A") == first ? "murmur" : "wispr")
                        return Verdict(id: id, murmurIs: first ? "A" : "B", winner: winner,
                                       murmurFlags: first ? fa : fb, wisprFlags: first ? fb : fa, reason: o["reason"] as? String ?? "")
                    }
                }
            }
            for _ in 0..<parallel { add() }
            while let v = try await group.next() {
                verdicts += v
                add()
            }
        }
        return verdicts
    }

    static func callClaude(system: String, input: String, model: String, effort: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["claude", "-p", "--model", model, "--no-session-persistence", "--tools", "", "--output-format", "text",
                           "--system-prompt", system] + (effort.map { ["--effort", $0] } ?? [])
            let inPipe = Pipe(), outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            let errPipe = Pipe()
            p.standardError = errPipe
            p.terminationHandler = { proc in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 { cont.resume(returning: String(decoding: data, as: UTF8.self)) }
                else {
                    let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile().suffix(300), as: UTF8.self)
                    let out = String(decoding: data.suffix(300), as: UTF8.self)
                    cont.resume(throwing: CLIError("claude exited \(proc.terminationStatus): \(err) \(out)"))
                }
            }
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try inPipe.fileHandleForWriting.close()
            } catch { cont.resume(throwing: error) }
        }
    }

    static func summarize(_ vs: [Verdict]) -> String {
        let n = vs.count
        let w = vs.filter { $0.winner == "murmur" }.count, t = vs.filter { $0.winner == "tie" }.count, l = vs.filter { $0.winner == "wispr" }.count
        func flags(_ k: String, _ f: KeyPath<Verdict, [String]>) -> Int { vs.filter { $0[keyPath: f].contains(k) }.count }
        let pct = n == 0 ? 0 : 100 * Double(w + t) / Double(n)
        return String(format: "n %d: Murmur wins %d, ties %d, loses %d; better or tied %.1f%% (bar 90%%).", n, w, t, l, pct)
            + " Judge flags on Murmur: answered \(flags("answered", \.murmurFlags)), added \(flags("added", \.murmurFlags)),"
            + " dropped \(flags("dropped", \.murmurFlags)), misspelled \(flags("misspelled", \.murmurFlags))."
            + " On Wispr: answered \(flags("answered", \.wisprFlags)), added \(flags("added", \.wisprFlags)),"
            + " dropped \(flags("dropped", \.wisprFlags)), misspelled \(flags("misspelled", \.wisprFlags))."
    }
}
