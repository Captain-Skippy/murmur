import Foundation

/// Word vote over several recognizers' transcripts of the same audio, keeping the primary
/// recognizer's text (punctuation, casing, numbers) wherever the others do not outvote it.
/// A word changes only when a strict majority of all transcripts agree on another reading;
/// words are inserted the same way, and dropped only next to a replaced word. ROVER with a
/// fixed pivot.
public enum TranscriptVote {
    struct Token {
        var display: String
        var key: String
        /// First word of a sentence in its own transcript (its capital may be positional).
        var start = false
        var lead: String { String(display.prefix { !$0.isLetter && !$0.isNumber }) }
        var trail: String {
            let core = display.drop { !$0.isLetter && !$0.isNumber }
            return String(core.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
        }
        var core: String {
            let t = trail
            return String(display.drop { !$0.isLetter && !$0.isNumber }.dropLast(t.count))
        }
    }

    static func key(_ w: Substring) -> String {
        var s = w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        while let f = s.first, !f.isLetter, !f.isNumber { s.removeFirst() }
        while let l = s.last, !l.isLetter, !l.isNumber { s.removeLast() }
        return s
    }

    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        for w in s.split(whereSeparator: \.isWhitespace) {
            var t = Token(display: String(w), key: key(w))
            guard !t.key.isEmpty else { continue }
            t.start = out.last.map { ".?!".contains($0.trail.last ?? " ") } ?? true
            out.append(t)
        }
        return out
    }

    /// `transcripts[0]` is the primary recognizer. With fewer than three transcripts there is no
    /// majority to find, so the primary stands.
    public static func vote(_ transcripts: [String]) -> String {
        let hyps = transcripts.map(tokens)
        guard hyps.count >= 3, let pivot = hyps.first else { return transcripts.first ?? "" }
        let need = hyps.count / 2 + 1
        // Per pivot slot: readings (key -> first token seen, count; "" = deleted).
        // Per gap before slot i: inserted runs (joined keys -> tokens, count, whether the source
        // put the previous word's punctuation after the run).
        var slot = pivot.map { [$0.key: (tok: Optional($0), n: 1)] }
        var gap = [[String: (toks: [Token], n: Int, punctAfter: Bool)]](repeating: [:], count: pivot.count + 1)
        for h in hyps.dropFirst() {
            var run: [Token] = []
            var beforeRun: Token?
            var lastH: Token?
            func flush(at i: Int) {
                guard !run.isEmpty else { return }
                let k = run.map(\.key).joined(separator: " ")
                let punctAfter = beforeRun.map { $0.trail.isEmpty } ?? false
                let prev = gap[i][k]
                gap[i][k] = (prev?.toks ?? run, (prev?.n ?? 0) + 1, prev?.punctAfter ?? punctAfter)
                run = []
            }
            var next = 0
            for op in Consensus.alignOps(pivot.map(\.key), h.map(\.key)) {
                switch op {
                case .match(let i, let j), .sub(let i, let j):
                    flush(at: i)
                    let t = h[j]
                    let prev = slot[i][t.key]
                    slot[i][t.key] = (prev?.tok ?? t, (prev?.n ?? 0) + 1)
                    lastH = t; next = i + 1
                case .del(let i):
                    flush(at: i)
                    slot[i]["", default: (nil, 0)].n += 1
                    next = i + 1
                case .ins(let j):
                    if run.isEmpty { beforeRun = lastH }
                    run.append(h[j]); lastH = h[j]
                }
            }
            flush(at: next)
        }

        var out: [Token] = []
        func insert(_ g: [String: (toks: [Token], n: Int, punctAfter: Bool)]) {
            guard let best = g.max(by: { $0.value.n < $1.value.n }), best.value.n >= need else { return }
            var run = best.value.toks
            guard let first = run.first else { return }
            let atStart = out.last.map { ".?!".contains($0.trail.last ?? " ") } ?? true
            if first.start, !atStart, first.core.dropFirst().allSatisfy({ !$0.isUppercase }) {
                run[0].display = first.lead + first.core.lowercased() + first.trail
            }
            // "return." + "again" -> "return again." when the source had no break before the run.
            if best.value.punctAfter, let last = out.last, !last.trail.isEmpty {
                out[out.count - 1] = Token(display: last.lead + last.core, key: last.key)
                if run[run.count - 1].trail.isEmpty { run[run.count - 1].display += last.trail }
            }
            out += run
        }
        // The majority reading per slot; nil keeps the primary's word.
        let winner: [(key: String, tok: Token?)?] = pivot.indices.map { i in
            let best = slot[i].max { $0.value.n < $1.value.n || ($0.value.n == $1.value.n && $1.key == pivot[i].key) }!
            return best.key != pivot[i].key && best.value.n >= need ? (best.key, best.value.tok) : nil
        }
        func replaced(_ i: Int) -> Bool { pivot.indices.contains(i) && winner[i].map { !$0.key.isEmpty } ?? false }
        for (i, p) in pivot.enumerated() {
            insert(gap[i])
            guard let best = winner[i] else { out.append(p); continue }
            if best.key.isEmpty {
                // A word only the primary heard goes only as part of a replaced span ("note book" ->
                // "Notebook"); alone, the others more often clipped it than the primary invented it.
                guard replaced(i - 1) || replaced(i + 1) else { out.append(p); continue }
                // Dropped word: its punctuation stays with the previous word.
                if let last = out.last, last.trail.isEmpty, !p.trail.isEmpty {
                    out[out.count - 1].display += p.trail
                }
                continue
            }
            let alt = best.tok!
            var core = alt.core
            if let f = p.core.first, f.isUppercase, let a = core.first, a.isLowercase { core = a.uppercased() + core.dropFirst() }
            // A capital that only marks the other transcript's sentence start.
            if alt.start, let f = p.core.first, f.isLowercase, core.dropFirst().allSatisfy({ !$0.isUppercase }) { core = core.lowercased() }
            out.append(Token(display: p.lead + core + p.trail, key: alt.key))
        }
        insert(gap[pivot.count])
        return out.map(\.display).joined(separator: " ")
    }
}
