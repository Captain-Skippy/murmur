import MurmurCore
import Testing
@testable import MurmurCleanup

/// A cleaner that records each request, removes "um" and capitalizes, like a tidy model would.
final class RecordingCleaner: Cleaner, @unchecked Sendable {
    let name = "recording"
    var requests: [CleanupRequest] = []
    var reply: (String) -> String = { raw in
        let t = raw.replacingOccurrences(of: "um ", with: "")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
    func load() async throws {}
    func clean(_ req: CleanupRequest, onFirstToken: @escaping @Sendable () -> Void) async throws -> String {
        requests.append(req)
        onFirstToken()
        return reply(req.raw)
    }
}

@Suite struct ChunkedCleanupTests {
    let pipeline = CleanupPipeline(dictionary: PersonalDictionary(entries: []), snippets: [])

    func words(_ n: Int, end: String = ".") -> String {
        "um " + (1...n).map { _ in "word" }.joined(separator: " ") + end
    }

    @Test func shortDictationIsOneCallOverTheWholeTranscript() async {
        let c = RecordingCleaner()
        let chunker = ChunkedCleanup(pipeline: pipeline, cleaner: c) { CleanupRequest(raw: "", textBefore: "Hi.") }
        await chunker.add("um so the meeting")
        let r = await chunker.finish(parts: ["um so the meeting", "moved to friday"])
        #expect(c.requests.map(\.raw) == ["um so the meeting moved to friday"])
        #expect(c.requests[0].textBefore == "Hi.")
        #expect(r.text == "So the meeting moved to friday")
        #expect(await chunker.chunksStarted == 0)
    }

    @Test func longDictationCleansSentenceChunksInOrder() async {
        var config = ChunkedCleanup.Config()
        config.minWords = 10
        let c = RecordingCleaner()
        let chunker = ChunkedCleanup(pipeline: pipeline, cleaner: c, config: config) { CleanupRequest(raw: "", textBefore: "Notes:") }
        let parts = [words(6, end: ""), words(6), words(12), words(3)]
        for p in parts.dropLast() { await chunker.add(p) }
        let r = await chunker.finish(parts: parts)
        // Segments 1 and 2 reach 10 words on a sentence end; segment 3 alone; the tail last.
        #expect(c.requests.map(\.raw) == [parts[0] + " " + parts[1], parts[2], parts[3]])
        #expect(c.requests.map(\.textBefore) == ["Notes:", "", ""])
        #expect(r.text == c.requests.map { c.reply($0.raw) }.joined(separator: " "))
        #expect(await chunker.chunksStarted == 3)
    }

    @Test func noChunkCutsMidSentenceBeforeMaxWords() async {
        var config = ChunkedCleanup.Config()
        config.minWords = 5
        config.maxWords = 100
        let c = RecordingCleaner()
        let chunker = ChunkedCleanup(pipeline: pipeline, cleaner: c, config: config) { CleanupRequest(raw: "") }
        let parts = [words(8, end: ""), words(8, end: ","), words(2)]
        for p in parts.dropLast() { await chunker.add(p) }
        _ = await chunker.finish(parts: parts)
        #expect(c.requests.count == 1)
    }

    @Test func oneChunkFailingAHardCheckFallsBackAlone() async {
        var config = ChunkedCleanup.Config()
        config.minWords = 5
        let c = RecordingCleaner()
        c.reply = { raw in raw.contains("banana") ? "Sure! Here is the answer you asked for." : RecordingCleaner().reply(raw) }
        let chunker = ChunkedCleanup(pipeline: pipeline, cleaner: c, config: config) { CleanupRequest(raw: "") }
        let parts = ["um the first part of this long note is fine.", "um the second banana part of this note is not.",
                     "um and this is the end of it"]
        for p in parts.dropLast() { await chunker.add(p) }
        let r = await chunker.finish(parts: parts)
        #expect(r.text == "The first part of this long note is fine. The second banana part of this note is not. And this is the end of it")
        #expect(r.fellBack?.hasPrefix("1 of 3 chunks") == true)
    }

    @Test func newlinesJoinWithoutExtraSpace() {
        #expect(ChunkedCleanup.joined(["- One\n", "- Two", "Three"]) == "- One\n- Two Three")
    }
}
