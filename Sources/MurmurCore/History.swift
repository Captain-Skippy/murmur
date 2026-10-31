import Foundation

/// One dictation as the user saw it: kept for copy and re-insert, and for correction learning.
public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var at: Date
    public var app: String?
    public var raw: String
    public var text: String
    public var mode: String
    public var inserted: Bool

    public init(id: UUID = UUID(), at: Date = Date(), app: String?, raw: String, text: String, mode: String = "dictation", inserted: Bool) {
        self.id = id
        self.at = at
        self.app = app
        self.raw = raw
        self.text = text
        self.mode = mode
        self.inserted = inserted
    }
}

/// History in one private JSONL file per day, so retention is deleting whole old files.
public final class HistoryStore: @unchecked Sendable {
    public let dir: URL
    private let lock = NSLock()
    /// Counts appends and purges in this process, so a reader reloads only after a change.
    public private(set) var changes = 0

    public init(dir: URL = MurmurPaths.history) { self.dir = dir }

    public static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func file(for date: Date) -> URL { dir.appendingPathComponent("\(Self.dayFormat.string(from: date)).jsonl") }

    public func append(_ e: HistoryEntry) throws {
        lock.lock(); defer { lock.unlock() }
        try MurmurPaths.ensurePrivate(dir)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var line = try enc.encode(e)
        line.append(0x0A)
        let url = file(for: e.at)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        changes += 1
    }

    /// Newest first.
    public func recent(limit: Int = 20) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [HistoryEntry] = []
        for f in files {
            guard let d = try? Data(contentsOf: f) else { continue }
            let entries = d.split(separator: 0x0A).compactMap { try? dec.decode(HistoryEntry.self, from: Data($0)) }
            out += entries.reversed()
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    /// Delete day files older than `days` (by file date, UTC). Returns the files removed.
    @discardableResult
    public func purge(olderThanDays days: Int, now: Date = Date()) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        guard days > 0 else { return [] }
        let cutoff = Self.dayFormat.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.deletingPathExtension().lastPathComponent < cutoff }
        for f in files { try? FileManager.default.removeItem(at: f) }
        if !files.isEmpty { changes += 1 }
        return files
    }
}
