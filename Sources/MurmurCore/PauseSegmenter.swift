import Foundation

/// Finds pauses in live 16 kHz audio so an offline recognizer can decode finished
/// segments while the speaker is still talking; key release then decodes only the tail.
/// Cuts land in the middle of a silence, never inside a word.
public struct PauseSegmenter: Sendable {
    public struct Config: Sendable {
        public var sampleRate = 16_000
        public var frameMs = 20
        /// A pause at least this long is a cut candidate.
        public var minPauseMs = 350
        /// No cut before a segment has this much audio (short segments lose context).
        public var minSegmentSec = 4.0
        /// Force a cut at the quietest recent frame if nobody pauses for this long.
        public var maxSegmentSec = 24.0
        /// Silence is this far below the recent speech level...
        public var belowSpeechDb: Float = 18
        /// ...or this close to the noise floor.
        public var aboveFloorDb: Float = 6
        public init() {}
    }

    public let config: Config
    private var frameSamples: Int { config.sampleRate * config.frameMs / 1000 }
    private var pending: [Float] = []
    private var frameDb: [Float] = []          // one per frame since the last cut
    private var consumed = 0                    // samples turned into frames
    private var segmentStart = 0                // absolute sample index of the current segment
    private var floorDb: Float = -60
    private var speechDb: Float = -30
    private var silenceRun = 0

    public init(config: Config = Config()) { self.config = config }

    static func db(_ frame: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for x in frame { sum += x * x }
        let rms = (sum / Float(max(frame.count, 1))).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }

    /// Feed samples; returns absolute sample indices where a segment should end.
    public mutating func append(_ samples: [Float]) -> [Int] {
        pending.append(contentsOf: samples)
        var cuts: [Int] = []
        let n = frameSamples
        while pending.count >= n {
            let d = Self.db(pending[0..<n])
            pending.removeFirst(n)
            consumed += n
            frameDb.append(d)
            // Track the floor quickly downward, slowly upward; speech level the opposite.
            floorDb = d < floorDb ? d : floorDb + 0.002 * (d - floorDb)
            if d > speechDb { speechDb = d } else { speechDb += 0.005 * (d - speechDb) }
            let threshold = min(speechDb - config.belowSpeechDb, max(floorDb + config.aboveFloorDb, -70))
            silenceRun = d < threshold ? silenceRun + 1 : 0

            let segSec = Double(consumed - segmentStart) / Double(config.sampleRate)
            let pauseFrames = config.minPauseMs / config.frameMs
            if silenceRun >= pauseFrames && segSec >= config.minSegmentSec {
                // Cut in the middle of the silence run so both sides keep some quiet.
                let cut = consumed - (silenceRun / 2) * n
                cuts.append(cut)
                resetSegment(at: cut)
            } else if segSec >= config.maxSegmentSec {
                // Quietest frame in the last two seconds.
                let window = min(frameDb.count, 2000 / config.frameMs)
                let tail = frameDb.suffix(window)
                let idx = tail.indices.min { tail[$0] < tail[$1] } ?? (frameDb.count - 1)
                let framesAfter = frameDb.count - 1 - idx
                let cut = consumed - framesAfter * n - n / 2
                cuts.append(cut)
                resetSegment(at: cut)
            }
        }
        return cuts
    }

    private mutating func resetSegment(at cut: Int) {
        let keepFrames = max(0, (consumed - cut) / frameSamples)
        frameDb = Array(frameDb.suffix(keepFrames))
        segmentStart = cut
        silenceRun = 0
    }

    /// Offline use: all cut points for a whole clip.
    public static func cuts(for samples: [Float], config: Config = Config()) -> [Int] {
        var s = PauseSegmenter(config: config)
        var out: [Int] = []
        var i = 0
        while i < samples.count {
            let j = min(i + 1600, samples.count)
            out += s.append(Array(samples[i..<j]))
            i = j
        }
        return out
    }
}
