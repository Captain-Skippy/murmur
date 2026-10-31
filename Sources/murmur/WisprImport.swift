import Foundation
import MurmurCore
import SQLite3

/// Reads Wispr Flow's local history (read-only) into a private eval set. Wispr's database
/// is never modified; its audio and text stay under ~/Library/Application Support/Murmur.
enum WisprImport {
    /// Once Wispr Flow is uninstalled, a copy of its databases kept here is read instead.
    static var archive: URL { MurmurPaths.eval.appendingPathComponent("wispr-archive", isDirectory: true) }

    static var database: URL {
        let live = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wispr Flow/flow.sqlite")
        return FileManager.default.fileExists(atPath: live.path) ? live : archive.appendingPathComponent("flow.sqlite")
    }

    struct Row {
        var id: String
        var asr: String
        var formatted: String
        var pasted: String?
        var app: String?
        var latency: Double?
        var duration: Double
        var timestamp: String
        var context: String?
        var audio: Data
    }

    /// Wispr's own backup copies (it keeps audio for about two weeks; a backup reaches further back).
    static var backups: [URL] {
        [database.deletingLastPathComponent().appendingPathComponent("backups"), archive].flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("backup-") && $0.pathExtension == "sqlite" }
        }
    }

    static func open(_ url: URL? = nil) throws -> OpaquePointer {
        var db: OpaquePointer?
        let path = (url ?? database).path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? (url ?? database).path
        // Backups are opened immutable (they are never written); the live database read-only.
        let isLive = url == nil && database.path.contains("/Wispr Flow/")
        let uri = "file:\(path)?" + (isLive ? "mode=ro" : "immutable=1")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            throw CLIError("cannot open Wispr database read-only at \(database.path)")
        }
        sqlite3_busy_timeout(db, 5000)
        return db
    }

    static func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    static func rows(maxSeconds: Double, from url: URL? = nil) throws -> [Row] {
        let db = try open(url)
        defer { sqlite3_close(db) }
        let sql = """
            select transcriptEntityId, asrText, formattedText, app, e2eLatency, duration, timestamp, additionalContext, audio, pastedText
            from History where audio is not null and status = 'formatted' and asrText is not null and asrText != ''
            and duration > 0.5 and duration <= ? order by timestamp
            """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw CLIError("query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, maxSeconds)
        var out: [Row] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(st, 8))
            guard n > 44, let p = sqlite3_column_blob(st, 8) else { continue }
            out.append(Row(id: text(st, 0) ?? UUID().uuidString, asr: text(st, 1) ?? "", formatted: text(st, 2) ?? "", pasted: text(st, 9),
                           app: text(st, 3), latency: sqlite3_column_type(st, 4) == SQLITE_NULL ? nil : sqlite3_column_double(st, 4),
                           duration: sqlite3_column_double(st, 5), timestamp: text(st, 6) ?? "", context: text(st, 7),
                           audio: Data(bytes: p, count: n)))
        }
        return out
    }

    /// Every formatted pair in Wispr's history (with or without audio), for training data.
    static func allPairs() throws -> [(id: String, asr: String, pasted: String, app: String?, context: String?)] {
        let db = try open()
        defer { sqlite3_close(db) }
        let sql = """
            select transcriptEntityId, asrText, coalesce(pastedText, formattedText), app, additionalContext from History
            where status = 'formatted' and asrText is not null and asrText != '' and coalesce(pastedText, formattedText) is not null
            """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw CLIError("pairs query failed") }
        defer { sqlite3_finalize(st) }
        var out: [(id: String, asr: String, pasted: String, app: String?, context: String?)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((text(st, 0) ?? "", text(st, 1) ?? "", text(st, 2) ?? "", text(st, 3), text(st, 4)))
        }
        return out
    }

    /// Wispr rows since a date: id, finish time, raw, pasted text, app.
    static func rows(since: Date) throws -> [(id: String, at: Date, asr: String, pasted: String, app: String?)] {
        let db = try open()
        defer { sqlite3_close(db) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        var st: OpaquePointer?
        let sql = "select transcriptEntityId, timestamp, asrText, coalesce(pastedText, formattedText), app from History where status = 'formatted'"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw CLIError("rows query failed") }
        defer { sqlite3_finalize(st) }
        var out: [(id: String, at: Date, asr: String, pasted: String, app: String?)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let ts = text(st, 1), let at = f.date(from: ts), at >= since else { continue }
            out.append((text(st, 0) ?? "", at, text(st, 2) ?? "", text(st, 3) ?? "", text(st, 4)))
        }
        return out
    }

    /// Dictionary terms and snippets set up in Wispr.
    static func dictionary() throws -> (terms: [DictionaryEntry], snippets: [Snippet]) {
        let db = try open()
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select phrase, replacement, isSnippet from Dictionary where isDeleted = 0", -1, &st, nil) == SQLITE_OK else {
            throw CLIError("dictionary query failed")
        }
        defer { sqlite3_finalize(st) }
        var terms: [DictionaryEntry] = []
        var snippets: [Snippet] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let phrase = text(st, 0) ?? ""
            let replacement = text(st, 1)
            if sqlite3_column_int(st, 2) == 1 || (replacement.map { $0.count > 40 } ?? false) {
                if let r = replacement { snippets.append(Snippet(trigger: phrase, expansion: r)) }
            } else if let r = replacement, !r.isEmpty {
                terms.append(DictionaryEntry(term: r, sounds: [phrase], source: .wispr))
            } else {
                terms.append(DictionaryEntry(term: phrase, source: .wispr))
            }
        }
        return (terms, snippets)
    }

    static func screenTerms(_ json: String?) -> [String]? {
        guard let d = json?.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ax = o["ax_context"] as? [String] else { return nil }
        return ax
    }

    static func run(maxSeconds: Double) throws -> EvalSet {
        // Live database first; backups add clips whose audio Wispr has since dropped.
        var rows = try rows(maxSeconds: maxSeconds)
        var seen = Set(rows.map(\.id))
        for b in backups { for r in (try? self.rows(maxSeconds: maxSeconds, from: b)) ?? [] where !seen.contains(r.id) { rows.append(r); seen.insert(r.id) } }
        let dir = EvalSet.url("wispr")
        try MurmurPaths.ensurePrivate(dir.appendingPathComponent("audio"))
        let iso = ISO8601DateFormatter()
        let wisprDate = DateFormatter()
        wisprDate.locale = Locale(identifier: "en_US_POSIX")
        wisprDate.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        var items: [EvalItem] = []
        for r in rows {
            let rel = "audio/\(r.id).wav"
            let url = dir.appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: url.path) {
                try r.audio.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let samples = try AudioFile.read16k(url)
            let seconds = Double(samples.count) / 16_000
            var cats = [bucket(seconds)]
            if AudioFile.rmsDb(samples) < -42 { cats.append("quiet") }
            var item = EvalItem(id: r.id, audio: rel, seconds: seconds, categories: cats)
            item.app = r.app
            item.split = EvalItem.splitFor(id: r.id)
            item.wisprASR = r.asr
            item.wisprFormatted = r.formatted
            item.wisprPasted = r.pasted
            item.wisprLatencyMs = r.latency
            item.screenTerms = screenTerms(r.context)
            item.recordedAt = wisprDate.date(from: r.timestamp) ?? iso.date(from: r.timestamp)
            items.append(item)
        }
        let set = EvalSet(name: "wispr", dir: dir, items: items)
        try set.save()
        return set
    }

    static func bucket(_ s: Double) -> String {
        switch s {
        case ..<5: return "under5s"
        case ..<15: return "5to15s"
        case ..<30: return "15to30s"
        default: return "over30s"
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
