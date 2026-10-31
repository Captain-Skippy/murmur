import Foundation

/// Monotonic nanoseconds (mach continuous time). Stage timestamps are only compared with each other.
public func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// The stages of one dictation, in pipeline order. Every dictation logs these.
public enum Stage: String, Codable, CaseIterable, Sendable {
    /// micOpening: the secure-field check passed and the mic is being started. captureStarted: the
    /// first buffer arrived. audioLive: real sound, after the stale burst and silence of a mic
    /// waking up (see LiveSound).
    case keyDown, micOpening, captureStarted, audioLive, keyUp, asrFinal, cleanupFirstToken, cleanupDone, inserted
}

/// Stage timestamps for one dictation. Holds timings only, never content.
public struct DictationTimings: Codable, Sendable, Equatable {
    public var id: UUID
    public var wallStart: Date
    public var stamps: [Stage: UInt64]
    public var audioSeconds: Double
    public var app: String?
    /// Kind of microphone recorded from ("headset", "builtIn"), never its name.
    public var mic: String?
    /// The mic was already on (within the warm window) at the key down.
    public var micWarm: Bool?
    /// Hold or hands-free; absent in logs from older builds.
    public var hotkeyMode: String?
    /// Chunks a long dictation was cleaned in; absent when cleaned in one call.
    public var cleanupChunks: Int?
    public var recognizer: String
    public var cleaner: String
    /// Set when the cleanup LLM was skipped (fast path) or when a dictation was cancelled.
    public var note: String?

    public init(id: UUID = UUID(), wallStart: Date = Date(), recognizer: String, cleaner: String) {
        self.id = id
        self.wallStart = wallStart
        self.stamps = [:]
        self.audioSeconds = 0
        self.recognizer = recognizer
        self.cleaner = cleaner
    }

    public mutating func mark(_ stage: Stage, at nanos: UInt64 = monotonicNanos()) {
        stamps[stage] = nanos
    }

    /// Milliseconds from one stage to another, nil if either is missing or out of order.
    public func ms(from a: Stage, to b: Stage) -> Double? {
        guard let x = stamps[a], let y = stamps[b], y >= x else { return nil }
        return Double(y - x) / 1_000_000
    }

    /// Key release to text inserted: the headline latency.
    public var releaseToInsert: Double? { ms(from: .keyUp, to: .inserted) }
    public var keyDownToCapture: Double? { ms(from: .keyDown, to: .captureStarted) }
    public var keyDownToMicOpening: Double? { ms(from: .keyDown, to: .micOpening) }
    /// Key down to real sound: words spoken before this are lost.
    public var keyDownToAudio: Double? { ms(from: .keyDown, to: .audioLive) }
    public var asrTail: Double? { ms(from: .keyUp, to: .asrFinal) }
    public var cleanup: Double? { ms(from: .asrFinal, to: .cleanupDone) }
    public var cleanupTTFT: Double? { ms(from: .asrFinal, to: .cleanupFirstToken) }
    public var insert: Double? { ms(from: .cleanupDone, to: .inserted) }
}

/// Nearest-rank percentile. `p` in 0...100. Nil for an empty sample.
public func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
}

public struct LatencySummary: Sendable, Equatable {
    public var n: Int
    public var p50: Double?
    public var p95: Double?
    public init(_ values: [Double]) {
        n = values.count
        p50 = percentile(values, 50)
        p95 = percentile(values, 95)
    }
}

/// The latency targets, in one place so the bench, the timing log and the docs agree.
public enum LatencyBar {
    public static let releaseToInsertP50: Double = 500
    public static let releaseToInsertP95: Double = 1000
    public static let keyDownToCapture: Double = 50
}

/// Append-only JSONL of timings. Content never goes here.
public final class TimingLog: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "murmur.timinglog")

    public init(url: URL) { self.url = url }

    public func append(_ t: DictationTimings) {
        queue.async { [url] in
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard var line = try? enc.encode(TimingRecord(t)) else { return }
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    public func flush() { queue.sync {} }

    public func read() -> [TimingRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? dec.decode(TimingRecord.self, from: Data($0)) }
    }
}

/// The flattened, human-readable form written to the log: milliseconds per stage.
public struct TimingRecord: Codable, Sendable {
    public var id: UUID
    public var at: Date
    public var app: String?
    public var mic: String?
    public var micWarm: Bool?
    /// Hold or hands-free; absent in logs from older builds.
    public var hotkeyMode: String?
    public var cleanupChunks: Int?
    public var recognizer: String
    public var cleaner: String
    public var audioSeconds: Double
    public var keyDownToCaptureMs: Double?
    public var keyDownToMicOpeningMs: Double?
    public var keyDownToAudioMs: Double?
    public var asrTailMs: Double?
    public var cleanupFirstTokenMs: Double?
    public var cleanupMs: Double?
    public var insertMs: Double?
    public var releaseToInsertMs: Double?
    public var note: String?

    public init(_ t: DictationTimings) {
        id = t.id
        at = t.wallStart
        app = t.app
        mic = t.mic
        micWarm = t.micWarm
        hotkeyMode = t.hotkeyMode
        cleanupChunks = t.cleanupChunks
        recognizer = t.recognizer
        cleaner = t.cleaner
        audioSeconds = t.audioSeconds
        keyDownToCaptureMs = t.keyDownToCapture
        keyDownToMicOpeningMs = t.keyDownToMicOpening
        keyDownToAudioMs = t.keyDownToAudio
        asrTailMs = t.asrTail
        cleanupFirstTokenMs = t.cleanupTTFT
        cleanupMs = t.cleanup
        insertMs = t.insert
        releaseToInsertMs = t.releaseToInsert
        note = t.note
    }
}
