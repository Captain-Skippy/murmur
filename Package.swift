// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "murmur", targets: ["murmur"]),
        .executable(name: "MurmurApp", targets: ["MurmurApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
        // Pinned: the package uses unsafe flags, which SwiftPM only accepts from a revision.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "b7c7971d94c4f73de910797593851d00858daf19"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "MurmurCore"),
        .target(name: "MurmurASR", dependencies: [
            "MurmurCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        ]),
        .target(name: "MurmurCleanup", dependencies: [
            "MurmurCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .executableTarget(name: "murmur", dependencies: ["MurmurCore", "MurmurASR", "MurmurCleanup"]),
        .executableTarget(name: "MurmurApp", dependencies: ["MurmurCore", "MurmurASR", "MurmurCleanup"]),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
        .testTarget(name: "MurmurCleanupTests", dependencies: ["MurmurCleanup", "MurmurCore"]),
        .testTarget(name: "MurmurASRTests", dependencies: ["MurmurASR", "MurmurCore"]),
    ],
    swiftLanguageModes: [.v5]
)
