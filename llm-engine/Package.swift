// swift-tools-version: 6.0
import PackageDescription

// Spike package for the M2 LLM sidecar (`minutiae-llm`). Validates that
// mlx-swift can load + stream from the chosen model on the Neural Engine/GPU
// before we build the NDJSON sidecar around it.
//
// The LLM/VLM libraries moved out of mlx-swift-examples into mlx-swift-lm; the
// `qwen3_5` architecture (Qwen3.5) is registered in MLXLLM's factory on `main`.
// The HF-download + tokenizer plumbing is supplied by the *consumer* via the
// MLXHuggingFace macros, so swift-huggingface + swift-transformers are direct
// deps here (versions matched to mlx-swift-lm's IntegrationTesting project).
//
// Pins: `branch: main` for newest arch support during the spike — pin a tag for
// the real sidecar once a release ships Qwen3.5.
let package = Package(
    name: "minutiae-llm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        .package(
            url: "https://github.com/huggingface/swift-huggingface",
            .upToNextMajor(from: "0.9.0")),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        // The real sidecar: NDJSON over stdio (docs/protocol/llm-ipc-v1.md).
        .executableTarget(
            name: "minutiae-llm",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Diagnostic harness — `minutiae-llm-spike [model] [prompt]`.
        .executableTarget(
            name: "minutiae-llm-spike",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
