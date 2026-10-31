import Foundation

/// One shadow-mode capture: Murmur listened while Wispr's key was held and ran its own
/// pipeline without inserting. Paired later with Wispr's history entry by time.
public struct ShadowEntry: Codable, Sendable {
    public var id: String
    public var startedAt: Date
    public var seconds: Double
    public var app: String?
    public var raw: String
    public var output: String
    public var recognizer: String
    public var cleaner: String
    public var asrTailMs: Double?
    public var cleanupMs: Double?

    public init(id: String, startedAt: Date, seconds: Double, app: String?, raw: String, output: String,
                recognizer: String, cleaner: String, asrTailMs: Double?, cleanupMs: Double?) {
        self.id = id
        self.startedAt = startedAt
        self.seconds = seconds
        self.app = app
        self.raw = raw
        self.output = output
        self.recognizer = recognizer
        self.cleaner = cleaner
        self.asrTailMs = asrTailMs
        self.cleanupMs = cleanupMs
    }

    /// Save as `<shadow>/<id>.wav` and `<id>.json`, private.
    public func save(samples: [Float], dir: URL = MurmurPaths.shadow) throws {
        try MurmurPaths.ensurePrivate(dir)
        try AudioFile.write16k(samples, to: dir.appendingPathComponent("\(id).wav"))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let url = dir.appendingPathComponent("\(id).json")
        try enc.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func all(dir: URL = MurmurPaths.shadow) -> [ShadowEntry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(ShadowEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Match Wispr history rows by time: Wispr stamps an entry when it finishes, so its
    /// timestamp falls between our start and a few seconds after our end.
    public static func match(_ e: ShadowEntry, wisprTimes: [(id: String, at: Date)]) -> String? {
        let lo = e.startedAt.addingTimeInterval(-2), hi = e.startedAt.addingTimeInterval(e.seconds + 8)
        return wisprTimes.filter { $0.at >= lo && $0.at <= hi }
            .min { abs($0.at.timeIntervalSince(e.startedAt)) < abs($1.at.timeIntervalSince(e.startedAt)) }?.id
    }
}
