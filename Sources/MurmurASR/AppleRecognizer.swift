import AVFoundation
import Foundation
import Speech

/// Apple's on-device recognizer (SpeechAnalyzer). `DictationTranscriber` honors contextual
/// strings (the dictionary, 100 max); `SpeechTranscriber` is the newer model and ignores them.
public final class AppleSpeechRecognizer: Recognizer, @unchecked Sendable {
    public enum Kind: String, Sendable { case dictation, speech }
    public let kind: Kind
    public var name: String { "apple-\(kind.rawValue)" }
    private let locale = Locale(identifier: "en_US")
    private var contextual: [String] = []
    private var format: AVAudioFormat?

    public init(kind: Kind) { self.kind = kind }

    private func module() -> any SpeechModule {
        switch kind {
        case .dictation:
            return DictationTranscriber(locale: locale, preset: .shortDictation)
        case .speech:
            return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        }
    }

    public func load() async throws {
        let m = module()
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) {
            try await req.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [m]) == .installed else {
            throw RecognizerError.unavailable("Apple speech assets for en_US are not installed")
        }
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m])
        try await warmUp()
    }

    public func setVocabulary(_ terms: [String]) async throws {
        contextual = Array(terms.prefix(100))
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let m = module()
        let ctx = AnalysisContext()
        if kind == .dictation && !contextual.isEmpty { ctx.contextualStrings[.general] = contextual }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [m],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime),
                                      analysisContext: ctx)
        let collector = Task { () -> String in
            var text = ""
            if let d = m as? DictationTranscriber {
                // Presets may report volatile results too; keep the last text per range start.
                var byStart: [Double: String] = [:]
                for try await r in d.results {
                    byStart[r.range.start.seconds] = String(r.text.characters)
                }
                text = byStart.keys.sorted().map { byStart[$0]! }.joined(separator: " ")
            } else if let s = m as? SpeechTranscriber {
                for try await r in s.results where r.isFinal { text += String(r.text.characters) }
            }
            return text
        }
        input.yield(AnalyzerInput(buffer: try Self.buffer(samples, as: format)))
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16 kHz mono Float32 samples converted to the analyzer's preferred format.
    static func buffer(_ samples: [Float], as target: AVAudioFormat?) throws -> AVAudioPCMBuffer {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let target, target != src else { return buf }
        guard let conv = AVAudioConverter(from: src, to: target) else {
            throw RecognizerError.unavailable("no converter to \(target)")
        }
        let ratio = target.sampleRate / src.sampleRate
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 1024)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let err { throw err }
        return out
    }
}
