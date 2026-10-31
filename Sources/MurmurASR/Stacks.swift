import Foundation

/// The recognizer stacks the bench and the app can run, by name.
public enum RecognizerStacks {
    public static let all = [
        "parakeet-v2", "parakeet-v2+boost", "parakeet-ultra", "parakeet-ultra+boost", "parakeet-unified",
        "cohere-transcribe", "qwen3-asr-1.7b", "qwen3-asr-0.6b", "apple-dictation", "apple-speech",
        "parakeet-unified+vote", "parakeet-unified+vote-cohere",
    ]

    /// Qwen3-ASR as a voter: at most 12 tokens per second of audio, so a hallucinated run on
    /// quiet audio cannot hold the GPU.
    static func cappedQwen() -> Qwen3ASRRecognizer {
        let q = Qwen3ASRRecognizer(repo: "mlx-community/Qwen3-ASR-1.7B-8bit")
        q.maxTokensPerSecond = 12
        return q
    }

    public static func make(_ name: String) throws -> any Recognizer {
        switch name {
        case "parakeet-v2": return ParakeetTDTRecognizer(version: .v2)
        case "parakeet-v2+boost": return ParakeetTDTRecognizer(version: .v2, boosting: true)
        case "parakeet-v3": return ParakeetTDTRecognizer(version: .v3)
        case "parakeet-ultra": return ParakeetTDTRecognizer(version: .ultra)
        case "parakeet-ultra+boost": return ParakeetTDTRecognizer(version: .ultra, boosting: true)
        case "parakeet-unified": return ParakeetUnifiedRecognizer()
        // Parakeet's text, corrected where Qwen3-ASR and Parakeet TDT v2 both hear another word
        // (bench.md). "+vote-cohere" votes with Cohere instead of v2: a little better, but Cohere
        // maps about 24 GB and adds about 600 ms at release.
        case "parakeet-unified+vote":
            return VotingRecognizer([ParakeetUnifiedRecognizer(), Self.cappedQwen(), ParakeetTDTRecognizer(version: .v2)])
        case "parakeet-unified+vote-cohere":
            return VotingRecognizer([ParakeetUnifiedRecognizer(), CohereRecognizer(), Self.cappedQwen()])
        case "cohere-transcribe": return CohereRecognizer()
        case "qwen3-asr-1.7b": return Qwen3ASRRecognizer(repo: "mlx-community/Qwen3-ASR-1.7B-8bit")
        case "qwen3-asr-0.6b": return Qwen3ASRRecognizer(repo: "mlx-community/Qwen3-ASR-0.6B-8bit")
        case "apple-dictation": return AppleSpeechRecognizer(kind: .dictation)
        case "apple-speech": return AppleSpeechRecognizer(kind: .speech)
        default: throw RecognizerError.unavailable("unknown stack \(name); known: \(all.joined(separator: ", "))")
        }
    }
}
