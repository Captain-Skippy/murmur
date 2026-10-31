import Foundation

/// What the running app reports in status.json for health checks: state, never content.
public struct AppStatus: Codable, Sendable, Equatable {
    public var updated: Date
    public var pid: Int32
    public var version: String
    public var status: String
    public var ready: Bool
    public var recognizer: String
    public var cleaner: String
    public var microphone: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool
    public var tapInstalled: Bool
    /// When the warm mic closes; nil while it is closed.
    public var micOpenUntil: Date?

    public init(updated: Date = Date(), pid: Int32, version: String, status: String, ready: Bool, recognizer: String,
                cleaner: String, microphone: Bool, accessibility: Bool, inputMonitoring: Bool, tapInstalled: Bool,
                micOpenUntil: Date? = nil) {
        self.updated = updated
        self.pid = pid
        self.version = version
        self.status = status
        self.ready = ready
        self.recognizer = recognizer
        self.cleaner = cleaner
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.tapInstalled = tapInstalled
        self.micOpenUntil = micOpenUntil
    }

    public static var url: URL { MurmurPaths.support.appendingPathComponent("status.json") }

    public func write(to url: URL = AppStatus.url) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? MurmurPaths.ensurePrivate(url.deletingLastPathComponent())
        try? enc.encode(self).write(to: url, options: .atomic)
    }
}
