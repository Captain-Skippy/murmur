import AppKit
import CoreGraphics
import MurmurCore

/// A session event tap that turns raw key events into state-machine events for the
/// dictation key, the command key, the control key and (in shadow mode) Wispr's Fn key. It passes every
/// event through, except Escape while Murmur is recording, which it consumes so a cancel
/// never reaches the app underneath (a coding agent in a terminal, for example).
final class HotkeyTap {
    enum Role { case dictation, command, control, shadow }

    var keys: [(HotkeyChoice, Role)] = []
    /// Main thread. Return true to consume the event (only used for Escape).
    var handler: ((Role, HotkeyStateMachine.Event) -> Bool)?
    /// Whether any role is recording (so Escape and other keys matter).
    var isRecording: () -> Bool = { false }

    private var tap: CFMachPort?
    private var held = Set<UInt16>()

    var installed: Bool { tap != nil }

    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            let me = Unmanaged<HotkeyTap>.fromOpaque(info!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: me) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func ms(_ e: CGEvent) -> Double {
        let now = monotonicNanos()
        let ts = e.timestamp
        // CGEvent timestamps are uptime nanoseconds; fall back to now if they look off.
        let use = (ts > 0 && ts <= now && now - ts < 1_000_000_000) ? ts : now
        return Double(use) / 1e6
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Keys voice control posts pass untouched: they are neither our hotkeys nor the user typing.
        if event.getIntegerValueField(.eventSourceUserData) == Commander.syntheticMark { return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let t = ms(event)
        if type == .flagsChanged {
            for (key, role) in keys where key.keyCode == code {
                let down = event.flags.rawValue & key.deviceMask != 0
                if down && !held.contains(code) {
                    held.insert(code)
                    _ = handler?(role, .keyDown(ms: t))
                } else if !down && held.contains(code) {
                    held.remove(code)
                    _ = handler?(role, .keyUp(ms: t))
                }
                return Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)
        }
        // Space while the dictation key is held (Fn+Space): hands-free. Consume the space,
        // and the one that may follow while a hands-free recording is being stopped.
        if code == 49, let d = keys.first(where: { $0.1 == .dictation }), held.contains(d.0.keyCode) {
            _ = handler?(.dictation, .handsFreeKey(ms: t))
            return nil
        }
        // keyDown of some other key.
        if code == 53, isRecording() {
            for (_, role) in keys where handler?(role, .escape) == true { return nil }
            return nil
        }
        if !held.isEmpty || isRecording() {
            for (_, role) in keys { _ = handler?(role, .otherKey(ms: t)) }
        }
        return Unmanaged.passUnretained(event)
    }
}
