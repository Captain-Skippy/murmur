import AppKit
import CoreAudio
import MurmurCore

/// Two soft 70 ms chimes, synthesized so no audio files ship. Quiet enough that the start
/// sound picked up by the mic does not turn into words. They play only in headphones the Mac
/// already has (`ChimeRoute`), so they never pull AirPods away from the iPhone.
@MainActor
enum Sounds {
    static let start = make(from: 660, to: 880)
    static let stop = make(from: 880, to: 620)
    static let error = make(from: 300, to: 240, seconds: 0.12)

    static func make(from f0: Double, to f1: Double, seconds: Double = 0.07) -> NSSound? {
        let rate = 44_100.0
        let n = Int(seconds * rate)
        var pcm = Data(capacity: n * 2)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let f = f0 + (f1 - f0) * t
            phase += 2 * .pi * f / rate
            let env = sin(.pi * t)  // smooth attack and release, no click
            let v = Int16(sin(phase) * env * 0.18 * 32_767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        return NSSound(data: wav)
    }

    static func play(_ s: NSSound?, enabled: Bool) {
        guard enabled, let s, outputAllowsSound() else { return }
        s.stop()
        s.play()
    }

    /// The default output right now: AirPods connecting or a jack plugged in changes it.
    static func outputAllowsSound() -> Bool {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return false }
        func uint(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
            var p = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(dev, &p, 0, nil, &sz, &v) == noErr ? v : nil
        }
        guard let transport = uint(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) else { return false }
        return ChimeRoute.allowed(transport: transport,
                                  dataSource: uint(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput))
    }
}
