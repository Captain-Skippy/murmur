import Foundation
import MurmurCore

/// An on-device recognizer that decodes a finished clip of 16 kHz mono Float32 audio.
/// Live dictation wraps one in `SegmentedSession`, which decodes pause-bounded segments
/// while the speaker talks.
public protocol Recognizer: AnyObject, Sendable {
    var name: String { get }
    /// Longest segment this recognizer should be handed (Cohere's decoder caps tokens per call).
    var maxSegmentSeconds: Double { get }
    /// Download if needed, load, and run a warm-up decode so the first dictation is not cold.
    func load() async throws
    /// Terms to bias toward. Empty turns biasing off.
    func setVocabulary(_ terms: [String]) async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

public extension Recognizer {
    var maxSegmentSeconds: Double { 24 }

    /// One second of low noise: enough to compile and page in every model stage.
    func warmUp() async throws {
        let noise = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
        _ = try await transcribe(noise)
    }
}

public enum RecognizerError: Error, CustomStringConvertible {
    case notLoaded(String)
    case unavailable(String)
    public var description: String {
        switch self {
        case .notLoaded(let s): return "\(s) is not loaded"
        case .unavailable(let s): return s
        }
    }
}

/// Live dictation over an offline recognizer: finished segments decode in the background
/// while audio arrives; `finish` decodes only the tail and joins the pieces in order.
public actor SegmentedSession {
    public let recognizer: any Recognizer
    private var segmenter: PauseSegmenter
    private var samples: [Float] = []
    private var lastCut = 0
    private var chain: Task<[String], Error> = Task { [] }
    public private(set) var segmentsDecodedEarly = 0
    /// Each segment decoded before release, in order, as soon as its text is known.
    private var onSegment: (@Sendable (String) async -> Void)?

    public init(recognizer: any Recognizer, segmenter: PauseSegmenter.Config = PauseSegmenter.Config()) {
        self.recognizer = recognizer
        var c = segmenter
        c.maxSegmentSec = min(c.maxSegmentSec, recognizer.maxSegmentSeconds)
        self.segmenter = PauseSegmenter(config: c)
    }

    public var sampleCount: Int { samples.count }

    public func setOnSegment(_ f: (@Sendable (String) async -> Void)?) { onSegment = f }

    public func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
        for cut in segmenter.append(chunk) where cut > lastCut {
            enqueue(Array(samples[lastCut..<cut]), early: true)
            lastCut = cut
            segmentsDecodedEarly += 1
        }
    }

    private func enqueue(_ segment: [Float], early: Bool) {
        let previous = chain
        let rec = recognizer
        let notify = early ? onSegment : nil
        chain = Task {
            var parts = try await previous.value
            let text = try await rec.transcribe(segment)
            parts.append(text)
            await notify?(text)
            return parts
        }
    }

    /// Decode the tail since the last pause and return the whole transcript.
    public func finish() async throws -> String {
        Self.join(try await finishParts())
    }

    /// Decode the tail since the last pause and return every segment's text in order.
    public func finishParts() async throws -> [String] {
        if samples.count > lastCut {
            // Pad very short tails: models misbehave under ~300 ms.
            var tail = Array(samples[lastCut...])
            if tail.count < 8_000 { tail += [Float](repeating: 0, count: 8_000 - tail.count) }
            enqueue(tail, early: false)
            lastCut = samples.count
        }
        return try await chain.value
    }

    /// The captured audio, for history, shadow mode and eval recordings.
    public func audio() -> [Float] { samples }

    public static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
