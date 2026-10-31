import Foundation

/// Every dictation kept for improving Murmur: audio, what the recognizer heard, what was
/// inserted, and what the field said 30 s later (the user's own fixes are the best labels).
/// Private, on this Mac only; kept `retentionDays` (90) then deleted by day.
public struct CorpusRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var at: Date
    public var app: String?
    public var style: String
    public var seconds: Double
    public var raw: String
    public var inserted: String
    /// Text before the cursor at the time (bounded), for context.
    public var before: String
    /// The focused field's text about 30 s after insertion (bounded), when readable.
    public var later: String?

    public init(id: UUID, at: Date, app: String?, style: String, seconds: Double, raw: String, inserted: String,
                before: String, later: String? = nil) {
        self.id = id
        self.at = at
        self.app = app
        self.style = style
        self.seconds = seconds
        self.raw = raw
        self.inserted = inserted
        self.before = before
        self.later = later
    }
}

public final class CorpusStore: @unchecked Sendable {
    public let dir: URL
    public static let retentionDays = 90
    private let lock = NSLock()

    public init(dir: URL = MurmurPaths.support.appendingPathComponent("corpus", isDirectory: true)) { self.dir = dir }

    func dayDir(_ d: Date) -> URL { dir.appendingPathComponent(HistoryStore.dayFormat.string(from: d), isDirectory: true) }

    public func save(_ r: CorpusRecord, samples: [Float]) throws {
        lock.lock(); defer { lock.unlock() }
        let d = dayDir(r.at)
        try MurmurPaths.ensurePrivate(dir)
        try MurmurPaths.ensurePrivate(d)
        try AudioFile.write16k(samples, to: d.appendingPathComponent("\(r.id.uuidString).wav"))
        try write(r, in: d)
    }

    /// Fill in `later` once the correction window has passed.
    public func update(id: UUID, at: Date, later: String) {
        lock.lock(); defer { lock.unlock() }
        let d = dayDir(at)
        let url = d.appendingPathComponent("\(id.uuidString).json")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), var r = try? dec.decode(CorpusRecord.self, from: data) else { return }
        r.later = String(later.suffix(6000))
        try? write(r, in: d)
    }

    private func write(_ r: CorpusRecord, in d: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let url = d.appendingPathComponent("\(r.id.uuidString).json")
        try enc.encode(r).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func all() -> [CorpusRecord] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let days = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return days.flatMap { day in
            ((try? FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .compactMap { try? dec.decode(CorpusRecord.self, from: Data(contentsOf: $0)) }
        }.sorted { $0.at < $1.at }
    }

    public func audioURL(_ r: CorpusRecord) -> URL { dayDir(r.at).appendingPathComponent("\(r.id.uuidString).wav") }

    /// Delete whole day folders older than the retention window. Returns what was removed.
    @discardableResult
    public func purge(now: Date = Date(), days: Int = CorpusStore.retentionDays) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = HistoryStore.dayFormat.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        let old = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent < cutoff }
        for d in old { try? FileManager.default.removeItem(at: d) }
        return old
    }
}
