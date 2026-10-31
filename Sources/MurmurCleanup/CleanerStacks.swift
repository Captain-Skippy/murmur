import Foundation
import MurmurCore

/// The cleanup options the bench and the app can run, by name.
public enum CleanerStacks {
    /// Name -> Hugging Face repo (MLX 4-bit). A "+lookup" suffix turns on prompt-lookup speculation.
    public static let models: [String: String] = [
        "qwen3-0.6b": "mlx-community/Qwen3-0.6B-4bit",
        "qwen3-1.7b": "mlx-community/Qwen3-1.7B-4bit",
        "qwen3-4b": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        "qwen3.5-2b": "mlx-community/Qwen3.5-2B-4bit",
        "gemma3-4b": "mlx-community/gemma-3-4b-it-qat-4bit",
        "gemma4-e2b": "mlx-community/gemma-4-e2b-it-4bit",
        "gemma4-e4b": "mlx-community/gemma-4-e4b-it-4bit",
        "llama3.2-3b": "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "lfm2-1.2b": "mlx-community/LFM2-1.2B-4bit",
        "qwen3-30b-a3b": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
    ]

    /// Models fine-tuned on this Mac live here, one folder each, named "tuned-<name>".
    public static var tunedRoot: URL { MurmurPaths.support.appendingPathComponent("models", isDirectory: true) }

    public static var tuned: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tunedRoot.path)) ?? []).filter { $0.hasPrefix("tuned-") }.sorted()
    }

    public static var all: [String] {
        ["none"] + models.keys.sorted().flatMap { [$0, $0 + "+lookup"] } + tuned.flatMap { [$0, $0 + "+lookup"] }
    }

    public static func make(_ name: String) throws -> any Cleaner {
        if name == "none" { return PassthroughCleaner() }
        let lookup = name.hasSuffix("+lookup")
        let base = lookup ? String(name.dropLast("+lookup".count)) : name
        if base.hasPrefix("tuned-") {
            let dir = tunedRoot.appendingPathComponent(base)
            guard FileManager.default.fileExists(atPath: dir.path) else { throw CleanerError.unknown(name) }
            return MLXCleaner(tunedDirectory: dir, name: name, speculate: lookup)
        }
        if let repo = models[base] { return MLXCleaner(repo: repo, speculate: lookup) }
        if base.contains("/") { return MLXCleaner(repo: base, speculate: lookup) }
        throw CleanerError.unknown(name)
    }
}

public enum CleanerError: Error, CustomStringConvertible {
    case unknown(String)
    case failed(String)
    public var description: String {
        switch self {
        case .unknown(let n): return "unknown cleaner \(n)"
        case .failed(let s): return s
        }
    }
}
