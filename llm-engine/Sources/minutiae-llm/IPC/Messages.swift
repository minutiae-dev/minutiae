// Hand-mirrored from docs/protocol/llm-ipc-v1.md — the protocol doc is the
// source of truth. Change this file, the doc, and app/src-tauri/src/llm_protocol.rs
// together. Wire format: NDJSON, snake_case keys, `"v": 1` envelope.

import Foundation

let protocolVersion = 1

// MARK: - Shared payload types

struct EnhanceOptions: Codable, Equatable, Sendable {
    var maxTokens: Int?
    var temperature: Double?
    var enableThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case maxTokens = "max_tokens"
        case temperature
        case enableThinking = "enable_thinking"
    }
}

struct Stats: Codable, Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var durationMs: Int
    var tokensPerS: Double

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case durationMs = "duration_ms"
        case tokensPerS = "tokens_per_s"
    }
}

enum FinishReason: String, Codable, Sendable {
    case stop, length, cancelled
}

enum ModelStage: String, Codable, Sendable {
    case downloading, loading
}

enum LlmErrorCode: String, Codable, Sendable {
    case modelDownloadFailed = "model_download_failed"
    case modelLoadFailed = "model_load_failed"
    case generationFailed = "generation_failed"
    case badRequest = "bad_request"
    case `internal` = "internal"
}

// MARK: - Core → llm

enum CoreMessage: Equatable, Sendable {
    case hello(id: String)
    case prepareModel(id: String, model: String)
    case enhance(id: String, model: String, prompt: String, system: String?, options: EnhanceOptions)
    case cancel(id: String, requestId: String)
    case ping(id: String)
    case shutdown
    /// Forward compatibility: unknown types decode here and are ignored.
    case unknown(type: String)
}

extension CoreMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case v, type, id, model, prompt, system, options
        case requestId = "request_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(id: try c.decode(String.self, forKey: .id))
        case "prepare_model":
            self = .prepareModel(id: try c.decode(String.self, forKey: .id),
                                 model: try c.decode(String.self, forKey: .model))
        case "enhance":
            self = .enhance(
                id: try c.decode(String.self, forKey: .id),
                model: try c.decode(String.self, forKey: .model),
                prompt: try c.decode(String.self, forKey: .prompt),
                system: try c.decodeIfPresent(String.self, forKey: .system),
                options: try c.decodeIfPresent(EnhanceOptions.self, forKey: .options) ?? EnhanceOptions())
        case "cancel":
            self = .cancel(id: try c.decode(String.self, forKey: .id),
                           requestId: try c.decode(String.self, forKey: .requestId))
        case "ping":
            self = .ping(id: try c.decode(String.self, forKey: .id))
        case "shutdown":
            self = .shutdown
        default:
            self = .unknown(type: type)
        }
    }
}

// Encodable too so tests can round-trip; the sidecar never sends these.
extension CoreMessage: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .v)
        switch self {
        case .hello(let id):
            try c.encode("hello", forKey: .type)
            try c.encode(id, forKey: .id)
        case .prepareModel(let id, let model):
            try c.encode("prepare_model", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(model, forKey: .model)
        case .enhance(let id, let model, let prompt, let system, let options):
            try c.encode("enhance", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(model, forKey: .model)
            try c.encode(prompt, forKey: .prompt)
            try c.encodeIfPresent(system, forKey: .system)
            try c.encode(options, forKey: .options)
        case .cancel(let id, let requestId):
            try c.encode("cancel", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(requestId, forKey: .requestId)
        case .ping(let id):
            try c.encode("ping", forKey: .type)
            try c.encode(id, forKey: .id)
        case .shutdown:
            try c.encode("shutdown", forKey: .type)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

// MARK: - llm → core

enum LlmMessage: Equatable, Sendable {
    case helloAck(id: String, protocolVersion: Int, runtime: String, loadedModel: String?)
    case modelProgress(pct: Double, stage: ModelStage)
    case modelReady(id: String, model: String)
    case llmToken(id: String, text: String)
    case llmDone(id: String, finishReason: FinishReason, stats: Stats)
    case error(code: LlmErrorCode, message: String, fatal: Bool, requestId: String?)
    case pong(id: String)
}

extension LlmMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case v, type, id
        case protocolVersion = "protocol_version"
        case runtime
        case loadedModel = "loaded_model"
        case pct, stage, model, text
        case finishReason = "finish_reason"
        case stats, code, message, fatal
        case requestId = "request_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .v)
        switch self {
        case .helloAck(let id, let protocolVersion, let runtime, let loadedModel):
            try c.encode("hello_ack", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(runtime, forKey: .runtime)
            try c.encodeIfPresent(loadedModel, forKey: .loadedModel)
        case .modelProgress(let pct, let stage):
            try c.encode("model_progress", forKey: .type)
            try c.encode(pct, forKey: .pct)
            try c.encode(stage, forKey: .stage)
        case .modelReady(let id, let model):
            try c.encode("model_ready", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(model, forKey: .model)
        case .llmToken(let id, let text):
            try c.encode("llm_token", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case .llmDone(let id, let finishReason, let stats):
            try c.encode("llm_done", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(finishReason, forKey: .finishReason)
            try c.encode(stats, forKey: .stats)
        case .error(let code, let message, let fatal, let requestId):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
            try c.encode(fatal, forKey: .fatal)
            try c.encodeIfPresent(requestId, forKey: .requestId)
        case .pong(let id):
            try c.encode("pong", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

// Decodable too so tests can round-trip; the sidecar never receives these.
extension LlmMessage: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello_ack":
            self = .helloAck(
                id: try c.decode(String.self, forKey: .id),
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                runtime: try c.decode(String.self, forKey: .runtime),
                loadedModel: try c.decodeIfPresent(String.self, forKey: .loadedModel))
        case "model_progress":
            self = .modelProgress(
                pct: try c.decode(Double.self, forKey: .pct),
                stage: try c.decode(ModelStage.self, forKey: .stage))
        case "model_ready":
            self = .modelReady(id: try c.decode(String.self, forKey: .id),
                               model: try c.decode(String.self, forKey: .model))
        case "llm_token":
            self = .llmToken(id: try c.decode(String.self, forKey: .id),
                             text: try c.decode(String.self, forKey: .text))
        case "llm_done":
            self = .llmDone(
                id: try c.decode(String.self, forKey: .id),
                finishReason: try c.decode(FinishReason.self, forKey: .finishReason),
                stats: try c.decode(Stats.self, forKey: .stats))
        case "error":
            self = .error(
                code: try c.decode(LlmErrorCode.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message),
                fatal: try c.decode(Bool.self, forKey: .fatal),
                requestId: try c.decodeIfPresent(String.self, forKey: .requestId))
        case "pong":
            self = .pong(id: try c.decode(String.self, forKey: .id))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown llm message type: \(type)"))
        }
    }
}

// MARK: - Wire coding helpers

enum Wire {
    /// One-line JSON, sorted keys for byte-stable output. No pretty printing on the wire.
    static func encode(_ msg: LlmMessage) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(msg)
    }

    static func decodeCore(_ data: Data) throws -> CoreMessage {
        try JSONDecoder().decode(CoreMessage.self, from: data)
    }
}
