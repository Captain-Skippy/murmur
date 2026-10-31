/// Which input "automatic" records from: the Mac's own microphone whenever it is listed. Any
/// app that prepares input on AirPods switches them to call mode until it quits, and in call
/// mode every sound starting or stopping rebuilds the link, so music drops out for half a
/// second. Without a built-in mic it skips an iPhone (Continuity: macOS hands the default to a
/// phone plugged in by USB) and virtual or aggregate devices (Zoom, Teams, BlackHole).
public enum MicChoice {
    public enum Kind: Equatable, Sendable { case builtIn, headset, external, phone, virtual }

    public struct Device: Equatable, Sendable {
        public var id: UInt32
        public var kind: Kind
        public init(id: UInt32, kind: Kind) { self.id = id; self.kind = kind }
    }

    /// CoreAudio transport type (a four-char code) to kind. Unknown (0) is what virtual drivers
    /// report; other unlisted transports (USB, Thunderbolt) are external mics.
    public static func kind(transport: UInt32) -> Kind {
        switch transport {
        case fourCC("bltn"): .builtIn
        case fourCC("blue"), fourCC("blea"): .headset
        case fourCC("ccwd"), fourCC("ccwl"): .phone
        case 0, fourCC("virt"), fourCC("grup"), fourCC("airp"), fourCC("rscr"), fourCC("rstr"): .virtual
        default: .external
        }
    }

    /// The built-in mic; otherwise the default if it is a voice device, then a headset, then an
    /// external mic; the default itself only when nothing else is listed.
    public static func automatic(default def: UInt32, devices: [Device]) -> UInt32 {
        if let d = devices.first(where: { $0.kind == .builtIn }) { return d.id }
        let voice: Set<Kind> = [.headset, .external]
        if let d = devices.first(where: { $0.id == def }), voice.contains(d.kind) { return def }
        for k in [Kind.headset, .external] {
            if let d = devices.first(where: { $0.kind == k }) { return d.id }
        }
        return def
    }

    static func fourCC(_ s: StaticString) -> UInt32 {
        s.withUTF8Buffer { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }
}
