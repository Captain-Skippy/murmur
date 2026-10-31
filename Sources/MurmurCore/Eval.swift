import AVFoundation
import Foundation

/// Where Murmur keeps private data on this Mac. Nothing here is ever committed or uploaded.
public enum MurmurPaths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
    }
    public static var eval: URL { support.appendingPathComponent("eval", isDirectory: true) }
    public static var history: URL { support.appendingPathComponent("history", isDirectory: true) }
    public static var shadow: URL { support.appendingPathComponent("shadow", isDirectory: true) }
    public static var settings: URL { support.appendingPathComponent("settings.json") }
    public static var dictionary: URL { support.appendingPathComponent("dictionary.json") }
    public static var timings: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Murmur/timings.jsonl")
    }

    /// Create a private (0700) directory.
    public static func ensurePrivate(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}

/// One utterance in an eval set: audio on disk plus whatever truth exists for it.
public struct EvalItem: Codable, Sendable, Identifiable {
    public var id: String
    /// Audio file name relative to the set directory.
    public var audio: String
    public var seconds: Double
    /// Categories used to split the bench table (for example: whisper, noisy, list, dictionary).
    public var categories: [String]
    /// Hand-checked words actually spoken (scripted set). Nil for history items.
    public var reference: String?
    /// The text a perfect cleanup produces, when known (scripted set).
    public var expectedText: String?
    public var expectation: HardChecks.Expectation?
    public var app: String?
    /// Wispr Flow's own outputs for the same audio (history import).
    public var wisprASR: String?
    public var wisprFormatted: String?
    /// What Wispr actually inserted (Markdown lists where `wisprFormatted` holds HTML).
    public var wisprPasted: String?
    public var wisprLatencyMs: Double?
    /// Terms Wispr read from the screen through accessibility at the time.
    public var screenTerms: [String]?
    /// Text before the cursor when dictated (Murmur's own corpus), for context.
    public var textBefore: String?
    public var recordedAt: Date?
    /// History items only: "test" (held out; cleanup is scored here) or "train" (its audio's
    /// transcript may be used to train cleanup). Fixed by a hash of the id.
    public var split: String?
    public var isTest: Bool { split != "train" }

    public static func splitFor(id: String) -> String {
        let h = id.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return h % 10 < 3 ? "test" : "train"
    }

    /// Set when the recording does not match its reference; benches skip the item.
    public var excluded: String?

    /// Wispr's inserted text, trimmed: the formatting reference.
    public var wisprText: String? {
        (wisprPasted ?? wisprFormatted)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(id: String, audio: String, seconds: Double, categories: [String] = []) {
        self.id = id
        self.audio = audio
        self.seconds = seconds
        self.categories = categories
    }
}

public struct EvalSet: Sendable {
    public let name: String
    public let dir: URL
    public var items: [EvalItem]

    public init(name: String, dir: URL, items: [EvalItem]) {
        self.name = name
        self.dir = dir
        self.items = items
    }

    public static func url(_ name: String) -> URL { MurmurPaths.eval.appendingPathComponent(name, isDirectory: true) }

    public static func load(_ name: String) throws -> EvalSet {
        let dir = url(name)
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.jsonl"))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let items = try data.split(separator: 0x0A).map { try dec.decode(EvalItem.self, from: Data($0)) }
        return EvalSet(name: name, dir: dir, items: items)
    }

    public func save() throws {
        try MurmurPaths.ensurePrivate(dir)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for i in items { out.append(try enc.encode(i)); out.append(0x0A) }
        try out.write(to: dir.appendingPathComponent("manifest.jsonl"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("manifest.jsonl").path)
    }

    public func audioURL(_ item: EvalItem) -> URL { dir.appendingPathComponent(item.audio) }
}

public enum AudioFile {
    /// Any audio file as 16 kHz mono Float32.
    public static func read16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: inBuf)
        if src.sampleRate == 16_000 && src.channelCount == 1 && src.commonFormat == .pcmFormatFloat32 {
            return Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0], count: Int(inBuf.frameLength)))
        }
        let conv = AVAudioConverter(from: src, to: target)!
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / src.sampleRate) + 4096
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// 16 kHz mono 16-bit PCM WAV, mode 0600.
    public static func write16k(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        data.reserveCapacity(data.count + samples.count * 2)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Peak-normalized RMS in dBFS, for the quiet-speech category and the HUD meter.
    public static func rmsDb(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return 20 * log10(max((sum / Float(samples.count)).squareRoot(), 1e-7))
    }
}
