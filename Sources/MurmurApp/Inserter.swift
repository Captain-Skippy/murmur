import AppKit
import ApplicationServices
import Carbon
import MurmurCore

/// Puts text at the cursor. Paste is the default: the pasteboard is saved with all its
/// types, the text is offered as a promise so the moment the target reads it is known
/// (that is the "inserted" timestamp), then the saved pasteboard is restored unless the
/// user copied something newer. Cmd+Z undoes a paste in one step.
@MainActor
final class Inserter: NSObject {
    struct Outcome {
        var method: InsertionMethod
        /// Monotonic nanos when the target read the text (paste) or the write returned.
        var insertedAt: UInt64?
        var ok: Bool
    }

    /// Rapid consecutive pastes share the user's original clipboard until restoration.
    private var pendingRestore: (snapshot: PasteboardSnapshot, changeCount: Int)?

    func insert(_ text: String, into focus: FocusSnapshot, overrides: [String: InsertionMethod]) async -> Outcome {
        let target = InsertionTarget(bundleID: focus.bundleID, secure: Focus.isSecure(focus.element))
        let method = InsertionPlanner.choose(for: target, overrides: overrides)
        switch method {
        case .none:
            return Outcome(method: .none, insertedAt: nil, ok: false)
        case .paste:
            let at = await paste(text)
            return Outcome(method: .paste, insertedAt: at, ok: at != nil)
        case .accessibility:
            guard let el = focus.element else { return Outcome(method: .accessibility, insertedAt: nil, ok: false) }
            let ok = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
            return Outcome(method: .accessibility, insertedAt: monotonicNanos(), ok: ok)
        case .keystrokes:
            type(text)
            return Outcome(method: .keystrokes, insertedAt: monotonicNanos(), ok: true)
        }
    }

    /// Returns when the target read the text, or nil if it never did within 1.5 s.
    func paste(_ text: String) async -> UInt64? {
        let pb = NSPasteboard.general
        let snapshot: PasteboardSnapshot
        if let pendingRestore, pb.changeCount == pendingRestore.changeCount {
            snapshot = pendingRestore.snapshot
        } else {
            snapshot = PasteboardSnapshot.capture(pb)
        }
        let promise = PasteboardPromise(text: text)
        let ours = promise.write(to: pb)
        pendingRestore = (snapshot, ours)

        Self.postCommandV()
        let read = await promise.waitForRead()
        // Restore once reads stop (apps may read more than once), off the critical path.
        Task { @MainActor in
            repeat { try? await Task.sleep(for: .milliseconds(200)) } while monotonicNanos() - promise.lastRead < 200_000_000
            // A promise must be resolved before the pasteboard is replaced.
            PasteboardInsertion.restoreIfUnchanged(snapshot, ourChangeCount: ours, to: pb)
            if self.pendingRestore?.changeCount == ours { self.pendingRestore = nil }
        }
        return read
    }

    static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = keyCode(for: "v") ?? 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Type text as Unicode keyboard events, 16 UTF-16 units per event.
    func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }

    /// Virtual key for a character in the current keyboard layout (Dvorak moves "v").
    static func keyCode(for char: Character) -> CGKeyCode? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let r = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if r == noErr, len == 1, Character(UnicodeScalar(chars[0])!) == char { return CGKeyCode(code) }
            }
            return nil
        }
    }
}
