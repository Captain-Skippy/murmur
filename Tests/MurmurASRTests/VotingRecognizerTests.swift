import Foundation
import Testing
@testable import MurmurASR

/// A recognizer that answers after a delay, or fails.
final class StubRecognizer: Recognizer, @unchecked Sendable {
    let name: String
    let text: String?
    let delay: Duration
    var vocabulary: [String] = []
    init(_ name: String, _ text: String?, delay: Duration = .zero) { self.name = name; self.text = text; self.delay = delay }
    func load() async throws {}
    func setVocabulary(_ terms: [String]) async throws { vocabulary = terms }
    func transcribe(_ samples: [Float]) async throws -> String {
        try await Task.sleep(for: delay)
        guard let text else { throw RecognizerError.unavailable(name) }
        return text
    }
}

@Suite struct VotingRecognizerTests {
    @Test func votersOutvoteThePrimary() async throws {
        let v = VotingRecognizer([StubRecognizer("p", "Press enter to choose Fren."), StubRecognizer("a", "Press enter to choose French."),
                                  StubRecognizer("b", "press enter to choose french")])
        #expect(try await v.transcribe([]) == "Press enter to choose French.")
        #expect(v.name == "p+vote")
    }

    @Test func lateOrFailedVoterSitsOut() async throws {
        let late = VotingRecognizer([StubRecognizer("p", "the cat"), StubRecognizer("a", "the hat"),
                                     StubRecognizer("b", "the hat", delay: .seconds(5))], grace: .milliseconds(50))
        let t0 = ContinuousClock.now
        #expect(try await late.transcribe([]) == "the cat")
        #expect(ContinuousClock.now - t0 < .seconds(1))
        let failed = VotingRecognizer([StubRecognizer("p", "the cat"), StubRecognizer("a", "the hat"), StubRecognizer("b", nil)])
        #expect(try await failed.transcribe([]) == "the cat")
    }

    @Test func primaryFailureThrowsAndOnlyPrimaryIsBiased() async throws {
        let v = VotingRecognizer([StubRecognizer("p", nil), StubRecognizer("a", "x"), StubRecognizer("b", "x")])
        await #expect(throws: RecognizerError.self) { try await v.transcribe([]) }
        let p = StubRecognizer("p", "x"), a = StubRecognizer("a", "x")
        try await VotingRecognizer([p, a, StubRecognizer("b", "x")]).setVocabulary(["Kubernetes"])
        #expect(p.vocabulary == ["Kubernetes"] && a.vocabulary.isEmpty)
    }
}
