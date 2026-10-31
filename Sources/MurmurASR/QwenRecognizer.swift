import Foundation
import MLX
import MLXAudioSTT

/// Qwen3-ASR through MLX on the GPU. Biasing is context text in the model's system prompt.
public final class Qwen3ASRRecognizer: Recognizer, @unchecked Sendable {
    public let repo: String
    public var name: String { "qwen3-asr-" + (repo.contains("0.6B") ? "0.6b" : "1.7b") + (repo.hasSuffix("4bit") ? "-4bit" : "") }
    private let box = ModelBox()
    private var context = ""
    /// Output tokens allowed per second of audio; nil: 1024 per call. A cap stops a hallucinated
    /// run on quiet audio from holding the GPU for seconds.
    public var maxTokensPerSecond: Double?

    actor ModelBox {
        var model: Qwen3ASRModel?
        func set(_ m: Qwen3ASRModel) { model = m }
        func run(_ samples: [Float], context: String, maxTokens: Int) throws -> String {
            guard let model else { throw RecognizerError.notLoaded("qwen3-asr") }
            let out = model.generate(audio: MLXArray(samples), maxTokens: maxTokens, context: context, language: "English")
            return out.text
        }
    }

    public init(repo: String = "mlx-community/Qwen3-ASR-1.7B-8bit") { self.repo = repo }

    public func load() async throws {
        await box.set(try await Qwen3ASRModel.fromPretrained(repo))
        try await warmUp()
    }

    public func setVocabulary(_ terms: [String]) async throws {
        context = terms.isEmpty ? "" : "Names and terms the speaker uses: " + terms.joined(separator: ", ") + "."
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let cap = maxTokensPerSecond.map { min(1024, 32 + Int($0 * Double(samples.count) / 16_000)) } ?? 1024
        return try await box.run(samples, context: context, maxTokens: cap).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
