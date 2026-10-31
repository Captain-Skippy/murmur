import Foundation

/// Push-to-talk semantics for a key held alone, independent of how key events arrive.
/// Hold to dictate; a quick double tap starts hands-free; a tap during hands-free stops.
/// Recording starts on the first key down so the first word is never lost; a lone quick
/// tap or a chord (another key within `chordMs`, the key used as a modifier: fn+arrow)
/// discards it. Keys pressed later (F11 mid-sentence) pass through and the recording goes on.
public struct HotkeyStateMachine: Sendable {
    public enum Event: Sendable, Equatable {
        case keyDown(ms: Double)
        case keyUp(ms: Double)
        /// Any other key pressed while ours is down or recording.
        case otherKey(ms: Double)
        /// Space pressed while our key is held: switch to hands-free (Wispr's Fn+Space).
        case handsFreeKey(ms: Double)
        case escape
    }

    public enum Action: Sendable, Equatable {
        case start
        case stopAndProcess
        case enterHandsFree
        /// Discard the recording without inserting anything.
        case cancel
    }

    public enum State: Sendable, Equatable {
        case idle
        case holding(since: Double, secondTap: Bool)
        case handsFree
        /// Hands-free was stopped by a key down; swallow the matching key up.
        case stopping
    }

    public private(set) var state: State = .idle
    private var lastTapUp: Double = -.infinity
    public var tapMs: Double
    public var doubleTapMs: Double
    public var chordMs: Double

    public init(tapMs: Double = 300, doubleTapMs: Double = 450, chordMs: Double = 400) {
        self.tapMs = tapMs
        self.doubleTapMs = doubleTapMs
        self.chordMs = chordMs
    }

    public var isRecording: Bool {
        switch state { case .holding, .handsFree: true; default: false }
    }

    public mutating func handle(_ e: Event) -> [Action] {
        switch (state, e) {
        case (.idle, .keyDown(let t)):
            state = .holding(since: t, secondTap: t - lastTapUp <= doubleTapMs)
            return [.start]
        case (.holding(let since, let second), .keyUp(let t)):
            if t - since < tapMs {
                if second {
                    state = .handsFree
                    lastTapUp = -.infinity
                    return [.enterHandsFree]
                }
                state = .idle
                lastTapUp = t
                return [.cancel]
            }
            state = .idle
            lastTapUp = -.infinity
            return [.stopAndProcess]
        case (.holding(let since, _), .otherKey(let t)):
            guard t - since < chordMs else { return [] }
            state = .idle
            lastTapUp = -.infinity
            return [.cancel]
        case (.holding, .escape):
            state = .idle
            lastTapUp = -.infinity
            return [.cancel]
        case (.holding, .handsFreeKey):
            state = .handsFree
            lastTapUp = -.infinity
            return [.enterHandsFree]
        case (.idle, .handsFreeKey):
            // Space before the key registered as held: start straight into hands-free.
            state = .handsFree
            return [.start, .enterHandsFree]
        case (.handsFree, .keyDown):
            state = .stopping
            return [.stopAndProcess]
        case (.handsFree, .escape):
            state = .idle
            return [.cancel]
        case (.stopping, .keyUp):
            state = .idle
            return []
        case (.idle, .otherKey):
            lastTapUp = -.infinity
            return []
        default:
            return []
        }
    }
}
