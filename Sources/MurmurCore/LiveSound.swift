/// When real sound begins in a capture. A mic waking up first hands over a short burst of
/// stale audio, then digital silence (about 110 ms built in, 0.5 to 1.4 s for AirPods), then
/// sound. Sound is the first non-silent buffer after the silence; a mic that shows no silence
/// within `graceNanos` was live from its first buffer. The silence is not exact zeros in float:
/// a buffer whose peak is under `silentPeak` (-90 dBFS, below any room) counts.
public struct LiveSound: Sendable {
    public var graceNanos: UInt64 = 250_000_000
    public var silentPeak: Float = 3.2e-5
    private var first: UInt64?
    private var sawSilence = false
    public private(set) var done = false

    public init() {}

    /// Feed each buffer in order: when it began and its peak magnitude. Returns when real sound
    /// began, once.
    public mutating func feed(began: UInt64, peak: Float) -> UInt64? {
        guard !done else { return nil }
        let silent = peak < silentPeak
        let start = first ?? began
        first = start
        if silent { sawSilence = true; return nil }
        if sawSilence { done = true; return began }
        if began >= start + graceNanos { done = true; return start }
        return nil
    }
}
