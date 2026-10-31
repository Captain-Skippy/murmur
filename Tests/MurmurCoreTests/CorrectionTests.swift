import Testing
@testable import MurmurCore

@Suite struct CorrectionTests {
    @Test func spellingFixOfInsertedNameIsProposed() {
        let p = CorrectionDetector.proposals(inserted: "Send it to Sara first. ",
                                             fieldAfterInsert: "Notes: Send it to Sara first.",
                                             fieldLater: "Notes: Send it to Sarah first.")
        #expect(p == [.init(heard: "Sara", corrected: "Sarah")])
    }

    @Test func casingFixIsProposed() {
        let p = CorrectionDetector.proposals(inserted: "ask kai about tailscale", fieldAfterInsert: "ask kai about tailscale",
                                             fieldLater: "ask kai about Tailscale")
        #expect(p == [.init(heard: "tailscale", corrected: "Tailscale")])
    }

    @Test func wordsTypedByHandAreIgnored() {
        let p = CorrectionDetector.proposals(inserted: "the build works", fieldAfterInsert: "Hello Dvid. the build works",
                                             fieldLater: "Hello David. the build works")
        #expect(p.isEmpty)
    }

    @Test func rewritesAreNotSpellingFixes() {
        let p = CorrectionDetector.proposals(inserted: "we should meet on Tuesday at noon",
                                             fieldAfterInsert: "we should meet on Tuesday at noon",
                                             fieldLater: "let us gather next Friday evening")
        #expect(p.isEmpty)
        let q = CorrectionDetector.proposals(inserted: "meet on Tuesday", fieldAfterInsert: "meet on Tuesday",
                                             fieldLater: "meet on Friday")
        #expect(q.isEmpty)  // different word, not a spelling of it
    }

    @Test func unchangedFieldProposesNothing() {
        #expect(CorrectionDetector.proposals(inserted: "x y z", fieldAfterInsert: "x y z", fieldLater: "x y z").isEmpty)
    }
}

@Suite struct CorrectionMoreTests {
    @Test func fixSurvivesTypingMoreAfterwards() {
        let p = CorrectionDetector.proposals(inserted: "Send it to Sara first. ", fieldAfterInsert: "Send it to Sara first.",
                                             fieldLater: "Send it to Sarah first. Also bring the slides and the notes from Monday.")
        #expect(p == [.init(heard: "Sara", corrected: "Sarah")])
    }
}
