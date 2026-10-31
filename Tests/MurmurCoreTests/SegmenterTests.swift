import Foundation
import Testing
@testable import MurmurCore

@Suite struct SegmenterTests {
    /// Speech-like signal: a 220 Hz tone with amplitude giving the requested dBFS RMS.
    func tone(_ seconds: Double, db: Float) -> [Float] {
        let n = Int(seconds * 16_000)
        let amp = powf(10, db / 20) * 2.0.squareRoot().float
        return (0..<n).map { amp * sinf(2 * .pi * 220 * Float($0) / 16_000) }
    }
    func quiet(_ seconds: Double) -> [Float] {
        // Low noise floor, not digital silence.
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -0.0003...0.0003, using: &g) }
    }

    @Test func cutsInsideALongPause() {
        let audio = tone(5, db: -20) + quiet(0.6) + tone(5, db: -20)
        let cuts = PauseSegmenter.cuts(for: audio)
        #expect(cuts.count == 1)
        let cutSec = Double(cuts[0]) / 16_000
        #expect(cutSec > 5.0 && cutSec < 5.6)
    }

    @Test func shortPauseIsNotACut() {
        let audio = tone(5, db: -20) + quiet(0.2) + tone(5, db: -20)
        #expect(PauseSegmenter.cuts(for: audio).isEmpty)
    }

    @Test func noCutBeforeMinimumSegment() {
        let audio = tone(2, db: -20) + quiet(0.6) + tone(2, db: -20)
        #expect(PauseSegmenter.cuts(for: audio).isEmpty)
    }

    @Test func forcedCutWithoutPauses() {
        let audio = tone(30, db: -20)
        let cuts = PauseSegmenter.cuts(for: audio)
        #expect(cuts.count == 1)
        let sec = Double(cuts[0]) / 16_000
        #expect(sec > 21.5 && sec <= 24.1)
    }

    @Test func whisperLevelSpeechStillSegments() {
        let audio = tone(5, db: -45) + quiet(0.6) + tone(5, db: -45)
        #expect(PauseSegmenter.cuts(for: audio).count == 1)
    }

    @Test func streamingMatchesOffline() {
        let audio = tone(5, db: -20) + quiet(0.6) + tone(6, db: -25) + quiet(0.8) + tone(3, db: -20)
        var s = PauseSegmenter()
        var live: [Int] = []
        var i = 0
        while i < audio.count { let j = min(i + 512, audio.count); live += s.append(Array(audio[i..<j])); i = j }
        #expect(live == PauseSegmenter.cuts(for: audio))
        #expect(live.count == 2)
    }
}

private extension Double { var float: Float { Float(self) } }
