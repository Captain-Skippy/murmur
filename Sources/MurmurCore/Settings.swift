import Foundation

/// A key held alone to dictate. Right-side modifiers are distinguished by their device bits.
public enum HotkeyChoice: String, Codable, Sendable, CaseIterable {
    case rightOption, rightCommand, fn, rightControl, rightShift

    public var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        case .rightControl: 62
        case .rightShift: 60
        }
    }

    /// NX_DEVICE* bit in CGEventFlags that is set while this exact key is down.
    public var deviceMask: UInt64 {
        switch self {
        case .rightOption: 0x40        // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x10       // NX_DEVICERCMDKEYMASK
        case .fn: 0x800000             // kCGEventFlagMaskSecondaryFn
        case .rightControl: 0x2000     // NX_DEVICERCTLKEYMASK
        case .rightShift: 0x04         // NX_DEVICERSHIFTKEYMASK
        }
    }

    public var label: String {
        switch self {
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .fn: "Fn (Globe)"
        case .rightControl: "Right Control"
        case .rightShift: "Right Shift"
        }
    }
}

public struct MurmurSettings: Codable, Sendable, Equatable {
    public var dictationKey: HotkeyChoice = .fn
    /// Held with text selected, rewrites it by a spoken instruction ("shorter"). Off by
    /// default: a modifier key also starts the mic on every shortcut it is part of.
    /// (Renamed from `commandKey`, which defaulted to Right Command; old files drop it.)
    public var rewriteKey: HotkeyChoice? = nil
    public var recognizer = "parakeet-unified"
    public var cleaner = "qwen3-4b+lookup"
    public var sounds = true
    /// "automatic" (the Mac's own mic when listed, see MicChoice), "builtin", or a device UID.
    public var microphone = "automatic"
    /// Minutes the mic stays on after a dictation, so the next one starts without the mic's
    /// warm-up and includes the moment before the key. The mic indicator shows meanwhile. 0: off.
    public var warmMicMinutes = 10.0
    public var historyDays = 7
    /// Content (transcripts, prompts) in logs. Off: logs hold timings only.
    public var debugLogging = false
    /// Record silently while Wispr's key (Fn) is held and pair results with Wispr's history.
    public var shadowMode = false
    public var styleOverrides: [String: AppStyle] = [:]
    public var insertionOverrides: [String: InsertionMethod] = [:]
    /// A menu bar icon. Off: reopening Murmur (Spotlight, double-click) shows its window.
    public var menuBarIcon = false
    /// Clean dictations longer than this many words in sentence chunks while the user talks
    /// (faster release; needs a cleaner trained on chunks, v7: bench.md "Chunked cleanup").
    /// 0: one cleanup call after release.
    public var cleanupChunkWords = 0
    /// Longest gap between two taps that counts as a double tap (hands-free).
    public var doubleTapMs = 450
    /// A press shorter than this is a tap, not a dictation.
    public var tapMs = 300

    public init() {}

    public static func load(from url: URL = MurmurPaths.settings) -> MurmurSettings {
        guard let d = try? Data(contentsOf: url) else { return MurmurSettings() }
        // Unknown or missing keys fall back to defaults, so old files keep working.
        let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(MurmurSettings()))) as? [String: Any] ?? [:]
        let saved = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let merged = base.merging(saved) { _, new in new }
        guard let md = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? JSONDecoder().decode(MurmurSettings.self, from: md) else { return MurmurSettings() }
        return s
    }

    public func save(to url: URL = MurmurPaths.settings) throws {
        try MurmurPaths.ensurePrivate(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
