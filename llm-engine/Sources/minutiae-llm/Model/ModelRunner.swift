import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Owns the resident MLX model and runs streamed generation. An actor so loads
/// and generations serialize (one at a time), matching the protocol's single
/// active generation. Cancellation is cooperative: the caller cancels the Task
/// running `generate`, and the stream loop checks `Task.isCancelled` per chunk.
actor ModelRunner {
    private var container: ModelContainer?
    private var loadedModel: String?

    enum RunnerError: Error { case notLoaded }

    var currentModel: String? { loadedModel }

    /// Ensure `model` is downloaded and resident, loading (and downloading on
    /// first use) if needed. Idempotent for an already-loaded model.
    func ensureLoaded(
        _ model: String,
        progress: @Sendable @escaping (Double, ModelStage) -> Void
    ) async throws {
        if loadedModel == model, container != nil { return }
        container = nil
        loadedModel = nil
        log("loading model \(model)")
        let loaded = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: model)
        ) { (p: Progress) in
            progress(p.fractionCompleted, .downloading)
        }
        container = loaded
        loadedModel = model
        log("model \(model) resident")
    }

    /// Stream a completion. `onToken` fires for each chunk in order. Returns the
    /// finish reason and an approximate completion-chunk count.
    ///
    /// Thinking is controlled the only way Qwen3.5 supports: the `enable_thinking`
    /// chat-template kwarg (via `additionalContext`). Qwen3.5 does NOT honor the
    /// `/think` `/no_think` soft switches, so we don't use them. Off → the
    /// template emits an empty `<think></think>` and the model answers directly;
    /// on → it reasons inside `<think>…</think>` (the opening tag lives in the
    /// prompt, so the stream begins with reasoning and contains the closing
    /// `</think>`). Sampling follows the model card's per-mode "general" preset.
    func generate(
        model: String,
        system: String?,
        prompt: String,
        options: EnhanceOptions,
        progress: @Sendable @escaping (Double, ModelStage) -> Void,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> (FinishReason, Int) {
        try await ensureLoaded(model, progress: progress)
        guard let container else { throw RunnerError.notLoaded }

        let thinking = options.enableThinking ?? false

        // Qwen3.5 model-card sampling (general-tasks preset per mode; top_k=20,
        // min_p=0, presence_penalty=1.5 are shared). A client-sent temperature
        // overrides the preset.
        var params = GenerateParameters()
        params.temperature = Float(options.temperature ?? (thinking ? 1.0 : 0.7))
        params.topP = thinking ? 0.95 : 0.8
        params.topK = 20
        params.minP = 0.0
        params.presencePenalty = 1.5
        let maxTokens = options.maxTokens ?? 1024
        params.maxTokens = maxTokens

        let session = ChatSession(
            container,
            instructions: (system?.isEmpty == false) ? system : nil,
            generateParameters: params,
            additionalContext: ["enable_thinking": thinking]
        )
        var completion = 0
        var finish: FinishReason = .stop
        for try await chunk in session.streamResponse(to: prompt) {
            if Task.isCancelled {
                finish = .cancelled
                break
            }
            onToken(chunk)
            completion += 1
            if completion >= maxTokens {
                finish = .length
                break
            }
        }
        return (finish, completion)
    }
}
