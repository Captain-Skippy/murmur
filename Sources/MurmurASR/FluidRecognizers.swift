import CoreML
import FluidAudio
import Foundation

/// Parakeet TDT (v2 English, v3, Ultra) on the Neural Engine through FluidAudio, with
/// optional CTC keyword boosting from the personal dictionary.
public final class ParakeetTDTRecognizer: Recognizer, @unchecked Sendable {
    public let version: AsrModelVersion
    public let boosting: Bool
    /// FluidAudio's default similarity floor over-replaces on real dictation (issue #967);
    /// 0.7 is the reporter's tuned value, and the bench measures it.
    public var boostMinSimilarity: Float = 0.7
    public var name: String { "parakeet-\(Self.label(version))" + (boosting ? "+boost" : "") }

    private let manager = AsrManager(config: .default)
    private var decoderLayers = 2
    private var ctcModels: CtcModels?
    private var boost: VocabularyBoostingSession?

    public init(version: AsrModelVersion, boosting: Bool = false) {
        self.version = version
        self.boosting = boosting
    }

    static func label(_ v: AsrModelVersion) -> String {
        switch v {
        case .v2: return "v2"
        case .v3: return "v3"
        case .ultra: return "ultra"
        case .redux: return "redux"
        case .tdtCtc110m: return "110m"
        case .tdtJa: return "ja"
        }
    }

    public func load() async throws {
        let models = try await AsrModels.downloadAndLoad(version: version)
        decoderLayers = models.version.decoderLayers
        try await manager.loadModels(models)
        if boosting {
            ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        }
        try await warmUp()
    }

    public func setVocabulary(_ terms: [String]) async throws {
        guard boosting, let ctc = ctcModels else { return }
        guard !terms.isEmpty else { boost = nil; return }
        let vocab = CustomVocabularyContext(
            terms: terms.map { CustomVocabularyTerm(text: $0) },
            minSimilarity: boostMinSimilarity)
        boost = try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        if let boost, let timings = result.tokenTimings,
           let out = await boost.rescore(text: result.text, tokenTimings: timings, audioSamples: samples) {
            return out.text
        }
        return result.text
    }
}

/// Parakeet Unified 0.6B: one checkpoint with punctuation, casing and inverse text
/// normalization; used here in batch mode on pause-bounded segments.
public final class ParakeetUnifiedRecognizer: Recognizer, @unchecked Sendable {
    public let name = "parakeet-unified"
    public let boosting: Bool
    private let manager = UnifiedAsrManager()
    private var ctcModels: CtcModels?

    public init(boosting: Bool = false) { self.boosting = boosting }

    public func load() async throws {
        try await manager.loadModels()
        if boosting { ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m) }
        try await warmUp()
    }

    public func setVocabulary(_ terms: [String]) async throws {
        guard boosting, let ctc = ctcModels, !terms.isEmpty else { return }
        let vocab = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }, minSimilarity: 0.7)
        try await manager.configureVocabularyBoosting(vocabulary: vocab, ctcModels: ctc)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await manager.transcribe(samples)
    }
}

/// Cohere Transcribe 03-2026 (2B, int8 encoder, ANE decoder) through FluidAudio.
public final class CohereRecognizer: Recognizer, @unchecked Sendable {
    public let name = "cohere-transcribe"
    /// The Core ML decoder emits at most 108 tokens per call; keep segments short enough.
    public var maxSegmentSeconds: Double { 15 }
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    public init() {}

    public func load() async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
        let dir = base.appendingPathComponent("cohere-transcribe/q8")
        let needed = [ModelNames.CohereTranscribe.encoderCompiledFile,
                      ModelNames.CohereTranscribe.decoderCacheExternalV2CompiledFile, "vocab.json"]
        if needed.contains(where: { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
            try await ModelHub.download(.cohereTranscribeCoreml, to: base)
        }
        models = try await CoherePipeline.loadModels(encoderDir: dir, decoderDir: dir, vocabDir: dir, decoderVariant: .v2)
        try await warmUp()
    }

    public func setVocabulary(_ terms: [String]) async throws {}

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let models else { throw RecognizerError.notLoaded(name) }
        if samples.count > CohereAsrConfig.maxSamples {
            return try await pipeline.transcribeLong(audio: samples, models: models, language: .english).text
        }
        return try await pipeline.transcribe(audio: samples, models: models, language: .english).text
    }
}
