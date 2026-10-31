import Foundation
import Testing
@testable import MurmurCore

@Suite struct ShadowTests {
    @Test func matchesWisprEntryFinishedJustAfter() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let e = ShadowEntry(id: "s", startedAt: start, seconds: 6, app: nil, raw: "", output: "", recognizer: "", cleaner: "",
                            asrTailMs: nil, cleanupMs: nil)
        let times: [(id: String, at: Date)] = [("before", start.addingTimeInterval(-30)), ("right", start.addingTimeInterval(7)),
                                               ("later", start.addingTimeInterval(40))]
        #expect(ShadowEntry.match(e, wisprTimes: times) == "right")
        #expect(ShadowEntry.match(e, wisprTimes: [("far", start.addingTimeInterval(60))]) == nil)
    }
}
