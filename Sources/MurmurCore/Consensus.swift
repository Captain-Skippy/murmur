import Foundation

/// A reference built from several recognizers when no human transcript exists: word-level
/// voting (ROVER-style) over hypotheses aligned to the medoid. Scoring each system against
/// the consensus of the *others* (leave-one-out) ranks systems, Wispr included, without
/// favoring any one of them. It estimates accuracy; hand-checked references settle it.
public enum Consensus {
    enum Op { case match(Int, Int), sub(Int, Int), del(Int), ins(Int) }

    /// Alignment ops turning `r` into `h` (indices into each).
    static func alignOps(_ r: [String], _ h: [String]) -> [Op] {
        let n = r.count, m = h.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n { for j in 1...m {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            } }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                ops.append(r[i - 1] == h[j - 1] ? .match(i - 1, j - 1) : .sub(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                ops.append(.del(i - 1)); i -= 1
            } else {
                ops.append(.ins(j - 1)); j -= 1
            }
        }
        return ops.reversed()
    }

    /// Consensus word sequence of normalized hypotheses. Ties keep the medoid's word.
    public static func vote(_ hyps: [[String]]) -> [String] {
        guard hyps.count > 1 else { return hyps.first ?? [] }
        // Medoid: least total distance to the others.
        let dist = hyps.map { a in hyps.reduce(0) { $0 + WER.align(a, $1).errors } }
        let p = dist.indices.min { dist[$0] < dist[$1] }!
        let pivot = hyps[p]
        // Per pivot slot: votes for a word (or deletion); per gap before a slot: inserted words.
        var slotVotes = [[String: Int]](repeating: [:], count: pivot.count)
        var gapVotes = [[String: Int]](repeating: [:], count: pivot.count + 1)
        for (k, h) in hyps.enumerated() {
            if k == p { for (i, w) in pivot.enumerated() { slotVotes[i][w, default: 0] += 1 }; continue }
            var slot = 0
            var inserted: [String] = []
            for op in alignOps(pivot, h) {
                switch op {
                case .match(let i, let j), .sub(let i, let j):
                    if !inserted.isEmpty { gapVotes[i][inserted.joined(separator: " "), default: 0] += 1; inserted = [] }
                    slotVotes[i][h[j], default: 0] += 1; slot = i + 1
                case .del(let i):
                    if !inserted.isEmpty { gapVotes[i][inserted.joined(separator: " "), default: 0] += 1; inserted = [] }
                    slotVotes[i]["", default: 0] += 1; slot = i + 1
                case .ins(let j):
                    inserted.append(h[j])
                }
            }
            if !inserted.isEmpty { gapVotes[slot][inserted.joined(separator: " "), default: 0] += 1 }
        }
        let half = hyps.count / 2
        var out: [String] = []
        for i in 0...pivot.count {
            if let (w, c) = gapVotes[i].max(by: { $0.value < $1.value }), c > half { out += w.split(separator: " ").map(String.init) }
            guard i < pivot.count else { break }
            let best = slotVotes[i].max { a, b in a.value < b.value || (a.value == b.value && b.key == pivot[i]) }!
            let pivotCount = slotVotes[i][pivot[i], default: 0]
            let choice = best.value > pivotCount ? best.key : pivot[i]
            if !choice.isEmpty { out.append(choice) }
        }
        return out
    }

    /// Positions where not every hypothesis agrees with `vote`: vote words some hypothesis
    /// substitutes or drops, plus gaps where some hypothesis inserts words.
    public static func disputed(vote: [String], hyps: [[String]]) -> Int {
        var slots = Set<Int>(), gaps = Set<Int>()
        for h in hyps {
            var next = 0
            for op in alignOps(vote, h) {
                switch op {
                case .match(let i, _): next = i + 1
                case .sub(let i, _), .del(let i): slots.insert(i); next = i + 1
                case .ins: gaps.insert(next)
                }
            }
        }
        return slots.count + gaps.count
    }

    /// Each system's WER against the consensus of the voters other than itself, summed over
    /// items. Voters should be one per model family. `hyps[item][system]` is the raw text,
    /// nil if that system has no output for the item. Default voters: every system.
    public static func leaveOneOut(systems: [String], hyps: [[String?]], voters: Set<String>? = nil) -> [String: WER.Result] {
        let voterIdx = Set(systems.indices.filter { voters?.contains(systems[$0]) ?? true })
        var out: [String: WER.Result] = [:]
        for (s, name) in systems.enumerated() {
            var total = WER.Result.zero
            for row in hyps {
                guard let mine = row[s] else { continue }
                let others = row.enumerated().compactMap { $0.offset == s || !voterIdx.contains($0.offset) ? nil : $0.element }
                    .map { WER.normalize($0) }
                guard others.count >= 2 else { continue }
                total = total + WER.align(vote(others), WER.normalize(mine))
            }
            out[name] = total
        }
        return out
    }
}
