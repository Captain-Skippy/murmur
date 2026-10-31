import MurmurCore

/// A few product names recognizers commonly mis-spell, seeded by `murmur dictionary seed`.
/// Everything personal (people, places, your own tools) goes in your dictionary.json or is
/// learned from your corrections, never guessed here.
enum BuiltInDictionary {
    /// Only terms with a spelling or casing a recognizer gets wrong; common words need no entry.
    static let tools = [
        "Claude Code", "Codex", "T3 Code", "Ghostty", "Zed", "GitHub", "Tailscale", "WireGuard", "Hugging Face",
        "LM Studio", "SwiftUI", "Xcode", "macOS", "iOS", "launchd", "MLX", "Parakeet", "FluidAudio",
        "Anthropic", "OpenAI", "xAI", "Grok", "Opus", "Sonnet", "Haiku", "Wispr Flow", "Murmur",
    ]

    static var entries: [DictionaryEntry] {
        tools.map { DictionaryEntry(term: $0, category: "tool", source: .manual) }
    }
}
