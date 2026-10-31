import AppKit
import AVFoundation
import CoreAudio
import MurmurCore
import os

/// Microphone capture as 16 kHz mono Float32. The input unit is prepared at launch and runs while
/// recording, then stays warm for `warmSeconds` after each dictation (the mic indicator shows):
/// a key down while warm records at once and includes the last `prerollSeconds` of sound. A cold
/// mic takes ~110 ms (built in) to deliver sound, enough to lose a first word.
///
/// Capture is an input-only HAL unit bound to the chosen device, not AVAudioEngine: the engine
/// follows the default devices, and with AirPods as the default input it switched them to call
/// mode while recording from the built-in microphone, until Murmur quit.
final class AudioCapture: @unchecked Sendable {
    private var input: HALInput?
    /// The input device the unit was built for; a different choice (a USB mic arriving, the
    /// device vanishing) needs a fresh unit.
    private var builtFor: AudioDeviceID = 0
    /// "automatic", "builtin", or a device UID (falls back to automatic when absent).
    var preference = "automatic"
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var firstBuffer = true
    private var live = LiveSound()
    /// Time real sound only for a fresh recording on a cold mic.
    private var watchSound = false
    private var pendingRebuild: DispatchWorkItem?
    /// Recording: samples go to `onSamples`.
    private(set) var running = false
    /// The mic runs between dictations, keeping only the pre-roll.
    private var warm = false
    private var coolDown: DispatchWorkItem?
    var warmSeconds: Double = 600
    var prerollSeconds: Double = 0.3
    /// Whether the last start found the mic warm, for the timings log.
    private(set) var startedWarm = false
    /// Main thread: when the warm mic will close, nil when it is closed.
    var onWarmChange: ((Date?) -> Void)?
    /// Shared with the audio thread: whether samples are delivered, and the pre-roll.
    private struct Feed { var delivering = false; var ring: [Float] = []; var pending: [Float] = [] }
    private let feed = OSAllocatedUnfairLock(initialState: Feed())
    /// A device appeared, vanished or became the default since the unit was built.
    private var stale = false
    private var builtDevices: [AudioDeviceID] = []
    /// Listens to the bound device: it vanishing or changing rate stops the unit.
    private var deviceListener: (AudioDeviceID, AudioObjectPropertyListenerBlock)?
    private let log = Logger(subsystem: "com.cjhorning.murmur", category: "capture")

    /// Called on the audio thread, in order.
    var onSamples: (([Float]) -> Void)?
    /// RMS in dBFS for the HUD, audio thread.
    var onLevel: ((Float) -> Void)?
    /// Monotonic nanos when the first buffer arrived, minus its own duration: when capture began.
    var onCaptureStarted: ((UInt64) -> Void)?
    /// The same for the first buffer that is not all zeros: when real sound began.
    var onAudioLive: ((UInt64) -> Void)?

    init() {
        // A device change marks the unit stale; while idle it is rebuilt shortly after if the
        // choice changed, so a key down never waits for a rebuild. Other processes' private
        // aggregates also change the device list, so compare the real ones.
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                guard let self else { return }
                if sel == kAudioHardwarePropertyDefaultInputDevice || Self.inputDevices().map(\.id) != self.builtDevices {
                    self.stale = true
                    self.rebuildWhenIdle()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            guard let self, self.warm else { return }
            self.shutDown()
        }
    }

    /// Kind of the device Murmur records from, for the timings log.
    private(set) var deviceKind = "unknown"

    func prepare() {
        let want = resolveDevice()
        builtFor = want
        let devices = Self.inputDevices()
        builtDevices = devices.map(\.id)
        deviceKind = devices.first { $0.id == want }.map { "\($0.kind)" } ?? "unknown"
        input = HALInput(device: want)
        if input == nil { log.error("could not open input device \(want)") }
        input?.onBuffer = { [weak self] buf in self?.handle(buf) }
        observeDevice(want)
    }

    /// The bound device vanishing or changing rate mid-recording (a USB mic unplugged, a
    /// headset switching modes): rebuild on the current choice and keep recording.
    private func observeDevice(_ id: AudioDeviceID) {
        if let (old, block) = deviceListener {
            for sel in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
                var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(old, &addr, .main, block)
            }
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.builtFor == id, self.running || self.warm else { return }
            let recording = self.running
            self.log.notice("input device changed while \(recording ? "recording" : "warm"); restarting")
            self.rebuild()
            do {
                if recording { try self.start(resuming: true) } else { try self.startUnit(deliver: false, resuming: false) }
            } catch { self.log.error("restart failed: \(error)") }
        }
        for sel in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &addr, .main, block)
        }
        deviceListener = (id, block)
    }

    /// The device the preference points at right now.
    func resolveDevice() -> AudioDeviceID {
        let devices = Self.inputDevices()
        switch preference {
        case "automatic":
            return MicChoice.automatic(default: Self.defaultInputDevice(),
                                       devices: devices.map { MicChoice.Device(id: $0.id, kind: $0.kind) })
        case "builtin": return devices.first { $0.builtIn }?.id ?? Self.defaultInputDevice()
        default: return devices.first { $0.uid == preference }?.id ?? Self.defaultInputDevice()
        }
    }

    struct InputDevice: Identifiable, Hashable {
        var id: AudioDeviceID
        var uid: String
        var name: String
        var kind: MicChoice.Kind
        /// A real built-in device, not an aggregate that reports a built-in transport.
        var builtIn: Bool
    }

    /// Every live device with input channels. Skips the private aggregates AVAudioEngine builds
    /// (in other processes) to follow the default devices: they report
    /// a built-in transport and come and go with AirPods and sleep.
    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n)
            guard n > 0 else { return nil }
            func string(_ sel: AudioObjectPropertySelector) -> String {
                var p = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var v: Unmanaged<CFString>?
                var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &p, 0, nil, &sz, &v) == noErr, let s = v?.takeRetainedValue() else { return "" }
                return s as String
            }
            func uint(_ sel: AudioObjectPropertySelector) -> UInt32 {
                var p = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var v: UInt32 = 0
                var sz = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(id, &p, 0, nil, &sz, &v)
                return v
            }
            let uid = string(kAudioDevicePropertyDeviceUID)
            guard uint(kAudioDevicePropertyDeviceIsAlive) != 0, !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            let transport = uint(kAudioDevicePropertyTransportType)
            return InputDevice(id: id, uid: uid, name: string(kAudioObjectPropertyName), kind: MicChoice.kind(transport: transport),
                               builtIn: uint(kAudioObjectPropertyClass) == kAudioDeviceClassID
                                   && transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// Devices arrive in bursts (AirPods add an input and an output): rebuild once they settle.
    private func rebuildWhenIdle() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stale, !self.running else { return }
            // Still the same live device (AirPods connecting while the built-in mic is chosen):
            // nothing to do, and the warm mic keeps running.
            if self.input != nil, self.resolveDevice() == self.builtFor, Self.isAlive(self.builtFor) {
                self.stale = false
                return
            }
            let wasWarm = self.warm
            self.rebuild()
            if wasWarm { try? self.startUnit(deliver: false, resuming: false) }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Throw the unit away and build one for the current choice of device.
    func rebuild() {
        if running || warm { shutDown(keepWarmWindow: true) }
        stale = false
        input = nil
        converter = nil
        converterInput = nil
        prepare()
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    static func nominalRate(_ id: AudioDeviceID) -> Double {
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
        return v
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// The unit's format is the device rate when it was built; a device that changed rate in
    /// place (a headset entering call mode) needs a new unit.
    private var rateMatches: Bool {
        guard let input else { return false }
        return input.format.sampleRate == Self.nominalRate(builtFor)
    }

    /// `resuming` continues a recording after a device change without re-reporting its start.
    func start(resuming: Bool = false) throws {
        guard !running else { return }
        coolDown?.cancel()
        if warm, !stale, resolveDevice() == builtFor, rateMatches {
            // Warm: deliver the pre-roll, then every buffer from now on.
            warm = false
            running = true
            startedWarm = true
            let keep = Int(prerollSeconds * 16_000)
            feed.withLock { f in
                f.pending = Array(f.ring.suffix(keep))
                f.ring = []
                f.delivering = true
            }
            if !resuming {
                let now = monotonicNanos()
                onCaptureStarted?(now)
                onAudioLive?(now)
            }
            return
        }
        if warm { shutDown(keepWarmWindow: true) }
        if stale || resolveDevice() != builtFor || !rateMatches { rebuild() }
        startedWarm = false
        try startUnit(deliver: true, resuming: resuming)
    }

    private func startUnit(deliver: Bool, resuming: Bool) throws {
        guard let input, rateMatches else {
            log.error("no usable input: device \(self.builtFor) at \(Self.nominalRate(self.builtFor)) Hz")
            throw CaptureError.noInput
        }
        let fmt = input.format
        if converterInput != fmt {
            converter = AVAudioConverter(from: fmt, to: target)
            converterInput = fmt
        }
        firstBuffer = deliver && !resuming
        watchSound = deliver && !resuming
        live = LiveSound()
        feed.withLock { $0 = Feed(delivering: deliver) }
        try input.start()
        if deliver { running = true } else { warm = true }
    }

    /// End a recording. The mic stays warm for `warmSeconds`, then closes.
    func stop() {
        guard running else { return }
        running = false
        feed.withLock { $0 = Feed() }
        guard warmSeconds > 0 else { shutDown(); return }
        warm = true
        coolDown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.running else { return }
            self.shutDown()
            self.onWarmChange?(nil)
        }
        coolDown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + warmSeconds, execute: work)
        onWarmChange?(Date().addingTimeInterval(warmSeconds))
    }

    /// Stop the unit and close the mic. `keepWarmWindow` is for a restart that warms it again.
    private func shutDown(keepWarmWindow: Bool = false) {
        guard running || warm else { return }
        input?.stop()
        running = false
        warm = false
        feed.withLock { $0 = Feed() }
        if !keepWarmWindow { coolDown?.cancel(); onWarmChange?(nil) }
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        let dur = UInt64(Double(buf.frameLength) / buf.format.sampleRate * 1e9)
        let now = monotonicNanos()
        let began = now > dur ? now - dur : now
        if firstBuffer { firstBuffer = false; onCaptureStarted?(began) }
        if watchSound, !live.done, let ch = buf.floatChannelData {
            let peak = UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)).reduce(Float(0)) { max($0, abs($1)) }
            if let at = live.feed(began: began, peak: peak) { onAudioLive?(at) }
        }
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        let keep = Int(prerollSeconds * 16_000)
        let deliver: [Float]? = feed.withLock { f in
            if f.delivering {
                guard !f.pending.isEmpty else { return samples }
                defer { f.pending = [] }
                return f.pending + samples
            }
            f.ring.append(contentsOf: samples)
            if f.ring.count > keep { f.ring.removeFirst(f.ring.count - keep) }
            return nil
        }
        guard let deliver else { return }
        onLevel?(AudioFile.rmsDb(samples))
        onSamples?(deliver)
    }

    enum CaptureError: Error { case noInput, start(OSStatus) }
}

/// An input-only AUHAL bound to one device before it starts. It never opens the default input
/// device or an aggregate of the defaults, so a Bluetooth headset that is the default stays in
/// music mode while another microphone records. Delivers Float32 mono at the device rate.
final class HALInput {
    let device: AudioDeviceID
    let format: AVAudioFormat
    /// Audio thread. The buffer is reused: copy what you keep before returning.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let unit: AudioUnit
    private let buffer: AVAudioPCMBuffer

    init?(device: AudioDeviceID) {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(comp, &made) == noErr, let u = made else { return nil }
        var on: UInt32 = 1, off: UInt32 = 0, dev = device
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        var hw = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // Input on element 1, no output, then the device: in this order, before initializing.
        guard AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32) == noErr,
              AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32) == noErr,
              AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr,
              AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &asbdSize) == noErr,
              hw.mSampleRate > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8192) else {
            AudioComponentInstanceDispose(u)
            return nil
        }
        var client = fmt.streamDescription.pointee
        guard AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, asbdSize) == noErr else {
            AudioComponentInstanceDispose(u)
            return nil
        }
        self.device = device
        self.unit = u
        self.format = fmt
        self.buffer = buf
        var cb = AURenderCallbackStruct(inputProc: { ref, flags, time, bus, frames, _ in
            Unmanaged<HALInput>.fromOpaque(ref).takeUnretainedValue().render(flags, time, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(u) == noErr else {
            AudioComponentInstanceDispose(u)
            return nil
        }
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let list = buffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        let err = AudioUnitRender(unit, flags, time, bus, frames, list)
        if err == noErr { onBuffer?(buffer) }
        return err
    }

    func start() throws {
        let err = AudioOutputUnitStart(unit)
        if err != noErr { throw AudioCapture.CaptureError.start(err) }
    }

    func stop() { AudioOutputUnitStop(unit) }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}
