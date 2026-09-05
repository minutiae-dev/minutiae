// Hand-mirrored from docs/protocol/sidecar-ipc-v1.md — the protocol doc is the
// source of truth. Change this file, the doc, and app/src-tauri/src/protocol.rs
// together. Wire format: NDJSON, snake_case keys, `"v": 1` envelope.

import Foundation

public let protocolVersion = 1

// MARK: - Shared payload types

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var sampleRate: Double
    public var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case uid, name
        case sampleRate = "sample_rate"
        case isDefault = "is_default"
    }

    public init(uid: String, name: String, sampleRate: Double, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.isDefault = isDefault
    }
}

/// Whether the far end is likely audible in the room (so the mic hears it too).
/// Advisory only — echo suppression decides for itself from correlation.
public enum OutputRoute: String, Codable, Sendable {
    case speakers
    case headphones
    case unknown
}

/// The device the far end plays out of, for the pre-recording headset hint.
public struct OutputDeviceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var transport: String
    public var route: OutputRoute

    public init(name: String, transport: String, route: OutputRoute) {
        self.name = name
        self.transport = transport
        self.route = route
    }
}

public enum Channel: String, Codable, Sendable {
    case me
    case them
}

public struct Segment: Codable, Equatable, Sendable {
    public var idx: Int
    public var channel: Channel
    public var t0: Double
    public var t1: Double
    public var text: String
    /// 0..1 engine-reported; -1 if unavailable.
    public var confidence: Double
    public var isFinal: Bool
    public var engine: String

    enum CodingKeys: String, CodingKey {
        case idx, channel, t0, t1, text, confidence
        case isFinal = "final"
        case engine
    }

    public init(idx: Int, channel: Channel, t0: Double, t1: Double, text: String,
                confidence: Double, isFinal: Bool, engine: String) {
        self.idx = idx
        self.channel = channel
        self.t0 = t0
        self.t1 = t1
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.engine = engine
    }
}

public struct AudioFileInfo: Codable, Equatable, Sendable {
    public var channel: Channel
    public var path: String
    public var codec: String
    public var container: String
    public var durationS: Double
    /// Sample rate OF THE FILE. The recording is encoded at
    /// `AudioFileWriter.maxOpusSampleRate` or the capture rate, whichever is
    /// lower — so this is not necessarily what the device delivered.
    public var sampleRate: Double
    /// Sample rate the DEVICE delivered. Carried separately because the core
    /// records it as the session's device metadata, where the file's encode
    /// rate would be wrong.
    public var sourceSampleRate: Double

    enum CodingKeys: String, CodingKey {
        case channel, path, codec, container
        case durationS = "duration_s"
        case sampleRate = "sample_rate"
        case sourceSampleRate = "source_sample_rate"
    }

    public init(channel: Channel, path: String, codec: String, container: String,
                durationS: Double, sampleRate: Double, sourceSampleRate: Double? = nil) {
        self.channel = channel
        self.path = path
        self.codec = codec
        self.container = container
        self.durationS = durationS
        self.sampleRate = sampleRate
        self.sourceSampleRate = sourceSampleRate ?? sampleRate
    }
}

public struct SessionStats: Codable, Equatable, Sendable {
    public var segments: Int
    public var droppedWindows: Int

    enum CodingKeys: String, CodingKey {
        case segments
        case droppedWindows = "dropped_windows"
    }

    public init(segments: Int, droppedWindows: Int) {
        self.segments = segments
        self.droppedWindows = droppedWindows
    }
}

public enum ErrorCode: String, Codable, Sendable {
    case tccDeniedMic = "tcc_denied_mic"
    case tccDeniedSystem = "tcc_denied_system"
    case tapFailed = "tap_failed"
    case deviceGone = "device_gone"
    case modelDownloadFailed = "model_download_failed"
    case sessionAlreadyActive = "session_already_active"
    case noActiveSession = "no_active_session"
    case badRequest = "bad_request"
    case `internal` = "internal"
}

public enum ModelProgressStage: String, Codable, Sendable {
    case downloading
    case compiling
}

// MARK: - Core → engine

public enum CoreMessage: Equatable, Sendable {
    /// `engine` is optional (additive, no protocol bump): the variant the user
    /// has selected, so `models_ready` in the ack answers for that one rather
    /// than the engine default. Omitted ⇒ default.
    case hello(id: String, engine: String?)
    /// `engine`/`language` are optional (additive, no protocol bump): they tell
    /// the engine which model variant to download/prepare. Omitted ⇒ default.
    case prepareModels(id: String, engine: String?, language: String?)
    case listDevices(id: String)
    case startSession(id: String, sessionId: String, dir: String,
                      micDeviceUid: String, engine: String, language: String,
                      themSource: String)
    case stopSession(id: String)
    case ping(id: String)
    case shutdown
    /// Forward compatibility: unknown types decode here and are ignored.
    case unknown(type: String)
}

extension CoreMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case v, type, id
        case sessionId = "session_id"
        case dir
        case micDeviceUid = "mic_device_uid"
        case engine, language
        case themSource = "them_source"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(id: try c.decode(String.self, forKey: .id),
                          engine: try c.decodeIfPresent(String.self, forKey: .engine))
        case "prepare_models":
            self = .prepareModels(
                id: try c.decode(String.self, forKey: .id),
                engine: try c.decodeIfPresent(String.self, forKey: .engine),
                language: try c.decodeIfPresent(String.self, forKey: .language))
        case "list_devices":
            self = .listDevices(id: try c.decode(String.self, forKey: .id))
        case "start_session":
            self = .startSession(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                dir: try c.decode(String.self, forKey: .dir),
                micDeviceUid: try c.decode(String.self, forKey: .micDeviceUid),
                engine: try c.decode(String.self, forKey: .engine),
                language: try c.decode(String.self, forKey: .language),
                // Optional for forward-compat; omitted ⇒ system process tap.
                themSource: try c.decodeIfPresent(String.self, forKey: .themSource) ?? "system")
        case "stop_session":
            self = .stopSession(id: try c.decode(String.self, forKey: .id))
        case "ping":
            self = .ping(id: try c.decode(String.self, forKey: .id))
        case "shutdown":
            self = .shutdown
        default:
            self = .unknown(type: type)
        }
    }
}

// Encodable too so tests can round-trip; the engine never sends these.
extension CoreMessage: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .v)
        switch self {
        case .hello(let id, let engine):
            try c.encode("hello", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(engine, forKey: .engine)
        case .prepareModels(let id, let engine, let language):
            try c.encode("prepare_models", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(engine, forKey: .engine)
            try c.encodeIfPresent(language, forKey: .language)
        case .listDevices(let id):
            try c.encode("list_devices", forKey: .type)
            try c.encode(id, forKey: .id)
        case .startSession(let id, let sessionId, let dir, let micDeviceUid, let engine, let language, let themSource):
            try c.encode("start_session", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(dir, forKey: .dir)
            try c.encode(micDeviceUid, forKey: .micDeviceUid)
            try c.encode(engine, forKey: .engine)
            try c.encode(language, forKey: .language)
            try c.encode(themSource, forKey: .themSource)
        case .stopSession(let id):
            try c.encode("stop_session", forKey: .type)
            try c.encode(id, forKey: .id)
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

// MARK: - Engine → core

public enum EngineMessage: Equatable, Sendable {
    case helloAck(id: String, protocolVersion: Int, engineVersions: [String: String], modelsReady: Bool)
    case modelsReady(id: String)
    /// `output` is optional (additive, no protocol bump): what the far end plays
    /// out of, so the UI can suggest a headset before recording.
    case devices(id: String, items: [DeviceInfo], output: OutputDeviceInfo?)
    case sessionStarted(id: String, sessionId: String, t0EpochMs: Int64)
    case modelProgress(pct: Double, stage: ModelProgressStage)
    case transcript(sessionId: String, segment: Segment)
    case levels(sessionId: String, meDb: Double, themDb: Double)
    case sessionStopped(id: String, sessionId: String, audio: [AudioFileInfo], stats: SessionStats)
    case error(code: ErrorCode, message: String, fatal: Bool, sessionId: String?)
    case pong(id: String)
}

extension EngineMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case v, type, id
        case protocolVersion = "protocol_version"
        case engineVersions = "engine_versions"
        case modelsReady = "models_ready"
        case items, output
        case sessionId = "session_id"
        case t0EpochMs = "t0_epoch_ms"
        case pct, stage, segment
        case meDb = "me_db"
        case themDb = "them_db"
        case audio, stats, code, message, fatal
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .v)
        switch self {
        case .helloAck(let id, let protocolVersion, let engineVersions, let modelsReady):
            try c.encode("hello_ack", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(engineVersions, forKey: .engineVersions)
            try c.encode(modelsReady, forKey: .modelsReady)
        case .modelsReady(let id):
            try c.encode("models_ready", forKey: .type)
            try c.encode(id, forKey: .id)
        case .devices(let id, let items, let output):
            try c.encode("devices", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(items, forKey: .items)
            try c.encodeIfPresent(output, forKey: .output)
        case .sessionStarted(let id, let sessionId, let t0EpochMs):
            try c.encode("session_started", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(t0EpochMs, forKey: .t0EpochMs)
        case .modelProgress(let pct, let stage):
            try c.encode("model_progress", forKey: .type)
            try c.encode(pct, forKey: .pct)
            try c.encode(stage, forKey: .stage)
        case .transcript(let sessionId, let segment):
            try c.encode("transcript", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(segment, forKey: .segment)
        case .levels(let sessionId, let meDb, let themDb):
            try c.encode("levels", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(meDb, forKey: .meDb)
            try c.encode(themDb, forKey: .themDb)
        case .sessionStopped(let id, let sessionId, let audio, let stats):
            try c.encode("session_stopped", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(audio, forKey: .audio)
            try c.encode(stats, forKey: .stats)
        case .error(let code, let message, let fatal, let sessionId):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
            try c.encode(fatal, forKey: .fatal)
            try c.encodeIfPresent(sessionId, forKey: .sessionId)
        case .pong(let id):
            try c.encode("pong", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

// Decodable too so tests can round-trip; the engine never receives these.
extension EngineMessage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello_ack":
            self = .helloAck(
                id: try c.decode(String.self, forKey: .id),
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                engineVersions: try c.decode([String: String].self, forKey: .engineVersions),
                modelsReady: try c.decode(Bool.self, forKey: .modelsReady))
        case "models_ready":
            self = .modelsReady(id: try c.decode(String.self, forKey: .id))
        case "devices":
            self = .devices(
                id: try c.decode(String.self, forKey: .id),
                items: try c.decode([DeviceInfo].self, forKey: .items),
                output: try c.decodeIfPresent(OutputDeviceInfo.self, forKey: .output))
        case "session_started":
            self = .sessionStarted(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                t0EpochMs: try c.decode(Int64.self, forKey: .t0EpochMs))
        case "model_progress":
            self = .modelProgress(
                pct: try c.decode(Double.self, forKey: .pct),
                stage: try c.decode(ModelProgressStage.self, forKey: .stage))
        case "transcript":
            self = .transcript(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                segment: try c.decode(Segment.self, forKey: .segment))
        case "levels":
            self = .levels(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                meDb: try c.decode(Double.self, forKey: .meDb),
                themDb: try c.decode(Double.self, forKey: .themDb))
        case "session_stopped":
            self = .sessionStopped(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                audio: try c.decode([AudioFileInfo].self, forKey: .audio),
                stats: try c.decode(SessionStats.self, forKey: .stats))
        case "error":
            self = .error(
                code: try c.decode(ErrorCode.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message),
                fatal: try c.decode(Bool.self, forKey: .fatal),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId))
        case "pong":
            self = .pong(id: try c.decode(String.self, forKey: .id))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown engine message type: \(type)"))
        }
    }
}

// MARK: - Wire coding helpers

public enum Wire {
    /// One-line JSON, sorted keys for byte-stable output. No pretty printing on the wire.
    public static func encode(_ msg: EngineMessage) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(msg)
    }

    public static func decodeCore(_ data: Data) throws -> CoreMessage {
        try JSONDecoder().decode(CoreMessage.self, from: data)
    }
}
