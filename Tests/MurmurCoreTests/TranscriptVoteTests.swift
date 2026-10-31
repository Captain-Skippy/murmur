import Testing
@testable import MurmurCore

@Suite struct TranscriptVoteTests {
    @Test func primaryStandsWithoutMajority() {
        let p = "Okay, is this table ready to ship?"
        #expect(TranscriptVote.vote([p, "okay is this cable ready to ship", "okay is the table ready to ship"]) == p)
        // Fewer than three transcripts: nothing to vote.
        #expect(TranscriptVote.vote([p, "something else"]) == p)
    }

    @Test func majorityReplacesWordKeepingPunctuation() {
        let v = TranscriptVote.vote(["Also, sorry, the cat didn't move.", "Also sorry the hat didn't move.", "also sorry, the hat didn't move"])
        #expect(v == "Also, sorry, the hat didn't move.")
        // Replacing the last word of a sentence keeps the primary's period.
        #expect(TranscriptVote.vote(["Press enter to choose Fren.", "Press enter to choose French.", "press enter to choose french"])
            == "Press enter to choose French.")
    }

    @Test func positionalCapitalIsNotCopied() {
        #expect(TranscriptVote.vote(["I said settings page here.", "I said. The settings page here.", "i said the settings page here"])
            == "I said the settings page here.")
    }

    @Test func majorityInsertsAndDrops() {
        // Inserted at the end: the primary's period moves after the run.
        #expect(TranscriptVote.vote(["Close the door.", "Close the door again.", "close the door again"]) == "Close the door again.")
        #expect(TranscriptVote.vote(["I can fix it.", "I think I can fix it.", "I think I can fix it"]) == "I think I can fix it.")
        // A word only the primary heard is dropped next to a replaced word; its punctuation stays.
        #expect(TranscriptVote.vote(["Check note book.", "Check Notebook.", "check notebook"]) == "Check Notebook.")
        // Alone, it stays: the others more likely clipped it.
        #expect(TranscriptVote.vote(["I've got a plan going.", "a plan going.", "A plan going"]) == "I've got a plan going.")
        #expect(TranscriptVote.vote(["Wash them and put them away.", "Wash them put them away.", "wash them put them away"]) == "Wash them and put them away.")
    }

    @Test func emptyPrimary() {
        #expect(TranscriptVote.vote(["", "Thank you.", "thank you"]) == "Thank you.")
        #expect(TranscriptVote.vote(["", "", "Thank you."]) == "")
    }
}
