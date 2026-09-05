// minutiae-llm-spike — proves mlx-swift can load and stream from the M2
// enhancement model before we build the NDJSON sidecar around it.
//
//   swift run --package-path llm-engine minutiae-llm-spike [model-id] [prompt]
//
// Defaults to the user's pick, mlx-community/Qwen3.5-4B-MLX-4bit (model_type
// "qwen3_5", registered in MLXLLM's factory on mlx-swift-lm@main). Streams
// generated text to stdout; progress + verdict + timing go to stderr.

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

let args = Array(CommandLine.arguments.dropFirst())
let modelId = args.first ?? "mlx-community/Qwen3.5-4B-MLX-4bit"
let prompt =
    args.count > 1
    ? args[1]
    : "You are summarizing a meeting. In two sentences, explain why local-first, "
        + "on-device meeting transcription matters for privacy."

err("model:  \(modelId)\nprompt: \(prompt)\n\nloading (first run downloads from Hugging Face)…\n")

let loadStart = Date()
do {
    let container = try await #huggingFaceLoadModelContainer(
        configuration: ModelConfiguration(id: modelId)
    ) { (progress: Progress) in
        err(String(format: "\r  download %3.0f%%   ", progress.fractionCompleted * 100))
    }
    let loadS = Date().timeIntervalSince(loadStart)
    err(String(format: "\n  loaded in %.1fs — generating:\n\n", loadS))

    let session = ChatSession(container)
    let genStart = Date()
    var chars = 0
    for try await chunk in session.streamResponse(to: prompt) {
        out(chunk)
        chars += chunk.count
    }
    let genS = Date().timeIntervalSince(genStart)
    err(
        String(
            format: "\n\nPASS: streamed %d chars in %.1fs (%.0f char/s). mlx-swift loads %@.\n",
            chars, genS, Double(chars) / max(genS, 0.001), modelId))
} catch {
    err("\n\nFAIL: \(error)\n")
    exit(1)
}
