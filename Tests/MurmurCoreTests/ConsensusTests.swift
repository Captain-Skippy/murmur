import Testing
@testable import MurmurCore

@Suite struct ConsensusTests {
    func w(_ s: String) -> [String] { WER.normalize(s) }

    @Test func majorityFixesEachSystemsOwnError() {
        let hyps = [w("meet kai merrow on friday"), w("meet kai marrow on friday"), w("meet kai merrow on monday")]
        #expect(Consensus.vote(hyps) == w("meet kai merrow on friday"))
    }

    @Test func insertionsNeedAMajority() {
        #expect(Consensus.vote([w("go home now"), w("go home right now"), w("go home now")]) == w("go home now"))
        #expect(Consensus.vote([w("go home now"), w("go home right now"), w("go home right now")]) == w("go home right now"))
    }

    @Test func deletionsNeedAMajority() {
        #expect(Consensus.vote([w("a b c d"), w("a c d"), w("a b c d")]) == w("a b c d"))
    }

    @Test func leaveOneOutScoresTheOddOneOut() {
        let systems = ["x", "y", "z"]
        let hyps: [[String?]] = [["the cat sat", "the cat sat", "the hat sat"], ["a b", "a b", nil]]
        let r = Consensus.leaveOneOut(systems: systems, hyps: hyps)
        #expect(r["x"]!.errors == 0)
        #expect(r["z"]!.errors == 1)
    }

    @Test func disputedCountsSlotsAndGaps() {
        let vote = ["a", "b", "c"]
        #expect(Consensus.disputed(vote: vote, hyps: [vote, vote]) == 0)
        #expect(Consensus.disputed(vote: vote, hyps: [vote, ["a", "x", "c"], ["a", "b", "c", "d"]]) == 2)
        #expect(Consensus.disputed(vote: vote, hyps: [["a", "c"], ["a", "y", "c"]]) == 1)
    }
}
