//! Sidecar IPC protocol v1 — hand-mirrored from `docs/protocol/sidecar-ipc-v1.md`.
//!
//! The doc is the source of truth. The other two twins are the Rust core
//! (`app/src-tauri/src/protocol.rs`) and the Swift macOS engine
//! (`engine/Sources/EngineCore/IPC/Messages.swift`). Change all together.
//!
//! Transport is NDJSON: requests core → engine on stdin, responses/events
//! engine → core on stdout. Every message carries `"v": 1` and
//! `"type": "<snake_case>"`. Requests carry an `id` echoed on the direct
//! response; events carry no `id`. Receivers must ignore unknown fields and
//! unknown message types.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const PROTOCOL_VERSION: u32 = 1;

/// Default "them" source: the system-audio loopback.
pub const THEM_SOURCE_SYSTEM: &str = "system";
fn them_source_system() -> String {
    THEM_SOURCE_SYSTEM.to_string()
}

// ---------------------------------------------------------------------------
// Core → engine

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CoreMessage {
    /// First message after spawn.
    Hello { v: u32, id: String },
    /// Ensure the engine's ASR models are downloaded, compiled and loaded.
    /// Idempotent. Progress streams as `model_progress`; completion is the
    /// correlated `models_ready` response, failure an `error`.
    PrepareModels {
        v: u32,
        id: String,
        /// Optional (additive, no protocol bump): which model variant to
        /// prepare, e.g. "nemotron-streaming-ml". Omitted ⇒ engine default.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        engine: Option<String>,
        /// Optional language hint paired with `engine`, e.g. "auto" / "en".
        #[serde(default, skip_serializing_if = "Option::is_none")]
        language: Option<String>,
    },
    /// Input (mic) devices.
    ListDevices { v: u32, id: String },
    StartSession {
        v: u32,
        id: String,
        session_id: String,
        /// An existing, writable session folder.
        dir: String,
        mic_device_uid: String,
        /// Engine id, e.g. "nemotron-streaming-ml".
        engine: String,
        /// BCP-47-ish, e.g. "en".
        language: String,
        /// "them" channel source: "system" (loopback, default) or an
        /// input-device UID to capture directly. Omitted on the wire ⇒ "system".
        #[serde(default = "them_source_system")]
        them_source: String,
    },
    /// Stops the active session; completion is signalled by `session_stopped`.
    StopSession { v: u32, id: String },
    /// Health check.
    Ping { v: u32, id: String },
    /// Graceful exit; equivalent to stdin EOF.
    Shutdown { v: u32 },
}

impl CoreMessage {
    pub fn hello(id: impl Into<String>) -> Self {
        Self::Hello {
            v: PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    pub fn prepare_models(id: impl Into<String>) -> Self {
        Self::PrepareModels {
            v: PROTOCOL_VERSION,
            id: id.into(),
            engine: None,
            language: None,
        }
    }

    /// Like `prepare_models`, but targets a specific model variant so the
    /// launch-time download/compile matches the user's selected `asr_model`.
    pub fn prepare_models_with(
        id: impl Into<String>,
        engine: impl Into<String>,
        language: impl Into<String>,
    ) -> Self {
        Self::PrepareModels {
            v: PROTOCOL_VERSION,
            id: id.into(),
            engine: Some(engine.into()),
            language: Some(language.into()),
        }
    }

    pub fn list_devices(id: impl Into<String>) -> Self {
        Self::ListDevices {
            v: PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn start_session(
        id: impl Into<String>,
        session_id: impl Into<String>,
        dir: impl Into<String>,
        mic_device_uid: impl Into<String>,
        engine: impl Into<String>,
        language: impl Into<String>,
        them_source: impl Into<String>,
    ) -> Self {
        Self::StartSession {
            v: PROTOCOL_VERSION,
            id: id.into(),
            session_id: session_id.into(),
            dir: dir.into(),
            mic_device_uid: mic_device_uid.into(),
            engine: engine.into(),
            language: language.into(),
            them_source: them_source.into(),
        }
    }

    pub fn stop_session(id: impl Into<String>) -> Self {
        Self::StopSession {
            v: PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    pub fn ping(id: impl Into<String>) -> Self {
        Self::Ping {
            v: PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    pub fn shutdown() -> Self {
        Self::Shutdown {
            v: PROTOCOL_VERSION,
        }
    }

    /// The request id, if this message type carries one.
    pub fn id(&self) -> Option<&str> {
        match self {
            Self::Hello { id, .. }
            | Self::PrepareModels { id, .. }
            | Self::ListDevices { id, .. }
            | Self::StartSession { id, .. }
            | Self::StopSession { id, .. }
            | Self::Ping { id, .. } => Some(id),
            Self::Shutdown { .. } => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Engine → core

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EngineMessage {
    HelloAck {
        v: u32,
        id: String,
        protocol_version: u32,
        /// e.g. {"nemotron-streaming-ml": "<semver/model rev>"}
        engine_versions: BTreeMap<String, String>,
        models_ready: bool,
    },
    /// Correlated response to `prepare_models`: models are now ready.
    ModelsReady { v: u32, id: String },
    Devices {
        v: u32,
        id: String,
        items: Vec<DeviceInfo>,
    },
    SessionStarted {
        v: u32,
        id: String,
        session_id: String,
        /// Anchors session-relative seconds to wall clock.
        t0_epoch_ms: u64,
    },
    /// Emitted during first-run model download/compile.
    ModelProgress {
        v: u32,
        pct: f64,
        /// "downloading" | "compiling" (kept open for forward compatibility)
        stage: String,
    },
    Transcript {
        v: u32,
        session_id: String,
        segment: Segment,
    },
    /// ~10 Hz while recording; dBFS floats (<= 0, -120 = silence).
    Levels {
        v: u32,
        session_id: String,
        me_db: f64,
        them_db: f64,
    },
    SessionStopped {
        v: u32,
        id: String,
        session_id: String,
        audio: Vec<AudioFileInfo>,
        stats: SessionStats,
    },
    Error {
        v: u32,
        code: ErrorCode,
        message: String,
        /// `true` means the engine process is no longer usable and will exit;
        /// the core respawns it.
        fatal: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    Pong {
        v: u32,
        id: String,
    },
    /// Forward compatibility: unknown message types must not kill the reader.
    #[serde(other)]
    Unknown,
}

impl EngineMessage {
    /// The echoed request id, if this message type carries one.
    pub fn id(&self) -> Option<&str> {
        match self {
            Self::HelloAck { id, .. }
            | Self::ModelsReady { id, .. }
            | Self::Devices { id, .. }
            | Self::SessionStarted { id, .. }
            | Self::SessionStopped { id, .. }
            | Self::Pong { id, .. } => Some(id),
            _ => None,
        }
    }

    // Convenience constructors for the common engine→core replies.

    pub fn pong(id: impl Into<String>) -> Self {
        Self::Pong {
            v: PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    pub fn models_ready(id: impl Into<String>) -> Self {
        Self::ModelsReady {
            v: PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    /// An `error` event with no associated session.
    pub fn error(code: ErrorCode, message: impl Into<String>, fatal: bool) -> Self {
        Self::Error {
            v: PROTOCOL_VERSION,
            code,
            message: message.into(),
            fatal,
            session_id: None,
        }
    }

    /// An `error` event tied to a specific session.
    pub fn session_error(
        code: ErrorCode,
        message: impl Into<String>,
        fatal: bool,
        session_id: impl Into<String>,
    ) -> Self {
        Self::Error {
            v: PROTOCOL_VERSION,
            code,
            message: message.into(),
            fatal,
            session_id: Some(session_id.into()),
        }
    }
}

// ---------------------------------------------------------------------------
// Shared payload types

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub uid: String,
    pub name: String,
    pub sample_rate: u32,
    pub is_default: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    /// Unique per session, monotonic across both channels.
    pub idx: u64,
    /// "me" | "them" (M4 adds "them:spk1" sub-labels — kept as a string).
    pub channel: String,
    /// Seconds from session start.
    pub t0: f64,
    pub t1: f64,
    pub text: String,
    /// 0..1, engine-reported; -1 if unavailable.
    pub confidence: f64,
    /// Non-final segments may be re-emitted with the same idx; replace in
    /// place. Only `final: true` segments are persisted to transcript.json.
    #[serde(rename = "final")]
    pub is_final: bool,
    pub engine: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AudioFileInfo {
    pub channel: String,
    pub path: String,
    pub codec: String,
    pub container: String,
    pub duration_s: f64,
    pub sample_rate: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionStats {
    pub segments: u64,
    pub dropped_windows: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    TccDeniedMic,
    TccDeniedSystem,
    TapFailed,
    DeviceGone,
    ModelDownloadFailed,
    SessionAlreadyActive,
    NoActiveSession,
    BadRequest,
    Internal,
    /// Forward compatibility: unknown codes must not break decoding.
    #[serde(other)]
    Unknown,
}

// ---------------------------------------------------------------------------
// Tests: round-trips for every message type + exact wire shapes against
// hand-written JSON from the protocol doc. Byte-shape parity with the core's
// `app/src-tauri/src/protocol.rs` tests is intentional.

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn rt_core(msg: CoreMessage) {
        let wire = serde_json::to_string(&msg).unwrap();
        let back: CoreMessage = serde_json::from_str(&wire).unwrap();
        assert_eq!(msg, back, "core round-trip failed for {wire}");
    }

    fn rt_engine(msg: EngineMessage) {
        let wire = serde_json::to_string(&msg).unwrap();
        let back: EngineMessage = serde_json::from_str(&wire).unwrap();
        assert_eq!(msg, back, "engine round-trip failed for {wire}");
    }

    fn segment() -> Segment {
        Segment {
            idx: 42,
            channel: "me".into(),
            t0: 12.48,
            t1: 17.02,
            text: "hello there".into(),
            confidence: 0.93,
            is_final: true,
            engine: "nemotron-streaming-ml".into(),
        }
    }

    fn audio_file(channel: &str) -> AudioFileInfo {
        AudioFileInfo {
            channel: channel.into(),
            // Windows writes Ogg/Opus, not CAF — see docs/windows-port.md.
            path: format!("/tmp/sessions/x/audio-{channel}.opus"),
            codec: "opus".into(),
            container: "ogg".into(),
            duration_s: 2621.4,
            sample_rate: 48_000,
        }
    }

    #[test]
    fn round_trip_every_core_message() {
        rt_core(CoreMessage::hello("01J1"));
        rt_core(CoreMessage::prepare_models("01J1B"));
        rt_core(CoreMessage::prepare_models_with(
            "01J1C",
            "nemotron-streaming-en",
            "en",
        ));
        rt_core(CoreMessage::list_devices("01J2"));
        rt_core(CoreMessage::start_session(
            "01J3",
            "01J9XYZ",
            "/tmp/sessions/x",
            "BuiltInMicrophoneDevice",
            "nemotron-streaming-ml",
            "en",
            "system",
        ));
        rt_core(CoreMessage::stop_session("01J4"));
        rt_core(CoreMessage::ping("01J5"));
        rt_core(CoreMessage::shutdown());
    }

    #[test]
    fn round_trip_every_engine_message() {
        rt_engine(EngineMessage::HelloAck {
            v: 1,
            id: "01J1".into(),
            protocol_version: 1,
            engine_versions: BTreeMap::from([("nemotron-streaming-ml".to_string(), "0.1.0".to_string())]),
            models_ready: true,
        });
        rt_engine(EngineMessage::models_ready("01J1B"));
        rt_engine(EngineMessage::Devices {
            v: 1,
            id: "01J2".into(),
            items: vec![DeviceInfo {
                uid: "{0.0.1.00000000}.{guid}".into(),
                name: "Microphone (Realtek)".into(),
                sample_rate: 48_000,
                is_default: true,
            }],
        });
        rt_engine(EngineMessage::SessionStarted {
            v: 1,
            id: "01J3".into(),
            session_id: "01J9XYZ".into(),
            t0_epoch_ms: 1_770_000_000_123,
        });
        rt_engine(EngineMessage::ModelProgress {
            v: 1,
            pct: 42.5,
            stage: "downloading".into(),
        });
        rt_engine(EngineMessage::Transcript {
            v: 1,
            session_id: "01J9XYZ".into(),
            segment: segment(),
        });
        rt_engine(EngineMessage::Levels {
            v: 1,
            session_id: "01J9XYZ".into(),
            me_db: -23.5,
            them_db: -120.0,
        });
        rt_engine(EngineMessage::SessionStopped {
            v: 1,
            id: "01J4".into(),
            session_id: "01J9XYZ".into(),
            audio: vec![audio_file("me"), audio_file("them")],
            stats: SessionStats {
                segments: 311,
                dropped_windows: 0,
            },
        });
        rt_engine(EngineMessage::session_error(
            ErrorCode::TapFailed,
            "could not start loopback capture",
            false,
            "01J9XYZ",
        ));
        rt_engine(EngineMessage::error(ErrorCode::Internal, "boom", true));
        rt_engine(EngineMessage::pong("01J5"));
    }

    #[test]
    fn wire_shape_start_session() {
        let msg = CoreMessage::start_session(
            "01JREQ",
            "01J9XYZ",
            "C:\\Users\\u\\AppData\\Roaming\\Minutiae\\sessions\\2026-06-10T14-30-22Z--01J9XYZ",
            "{0.0.1.00000000}.{guid}",
            "nemotron-streaming-ml",
            "en",
            "system",
        );
        let expected: Value = json!({
            "v": 1,
            "type": "start_session",
            "id": "01JREQ",
            "session_id": "01J9XYZ",
            "dir": "C:\\Users\\u\\AppData\\Roaming\\Minutiae\\sessions\\2026-06-10T14-30-22Z--01J9XYZ",
            "mic_device_uid": "{0.0.1.00000000}.{guid}",
            "engine": "nemotron-streaming-ml",
            "language": "en",
            "them_source": "system"
        });
        assert_eq!(serde_json::to_value(&msg).unwrap(), expected);
        let back: CoreMessage = serde_json::from_value(expected).unwrap();
        assert_eq!(back, msg);

        // them_source omitted on the wire ⇒ defaults to "system"
        let legacy: CoreMessage = serde_json::from_str(
            r#"{"v":1,"type":"start_session","id":"i","session_id":"s","dir":"/tmp",
                "mic_device_uid":"m","engine":"nemotron-streaming-ml","language":"en"}"#,
        )
        .unwrap();
        match legacy {
            CoreMessage::StartSession { them_source, .. } => assert_eq!(them_source, "system"),
            other => panic!("expected start_session, got {other:?}"),
        }
    }

    #[test]
    fn wire_shape_transcript() {
        let wire = r#"{
            "v": 1,
            "type": "transcript",
            "session_id": "01J9XYZ",
            "segment": {
                "idx": 42,
                "channel": "me",
                "t0": 12.48,
                "t1": 17.02,
                "text": "hello there",
                "confidence": 0.93,
                "final": true,
                "engine": "nemotron-streaming-ml"
            }
        }"#;
        let msg: EngineMessage = serde_json::from_str(wire).unwrap();
        assert_eq!(
            msg,
            EngineMessage::Transcript {
                v: 1,
                session_id: "01J9XYZ".into(),
                segment: segment(),
            }
        );
        assert_eq!(
            serde_json::to_value(&msg).unwrap(),
            serde_json::from_str::<Value>(wire).unwrap()
        );
    }

    #[test]
    fn wire_shape_hello_ack() {
        let wire = r#"{
            "v": 1,
            "type": "hello_ack",
            "id": "01JHELLO",
            "protocol_version": 1,
            "engine_versions": {"nemotron-streaming-ml": "0.1.0"},
            "models_ready": false
        }"#;
        let msg: EngineMessage = serde_json::from_str(wire).unwrap();
        assert_eq!(
            msg,
            EngineMessage::HelloAck {
                v: 1,
                id: "01JHELLO".into(),
                protocol_version: 1,
                engine_versions: BTreeMap::from([(
                    "nemotron-streaming-ml".to_string(),
                    "0.1.0".to_string()
                )]),
                models_ready: false,
            }
        );
        assert_eq!(
            serde_json::to_value(&msg).unwrap(),
            serde_json::from_str::<Value>(wire).unwrap()
        );
    }

    #[test]
    fn unknown_engine_message_type_decodes_to_unknown() {
        let msg: EngineMessage =
            serde_json::from_str(r#"{"v":1,"type":"telemetry_blob","payload":{"x":1}}"#).unwrap();
        assert_eq!(msg, EngineMessage::Unknown);
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let msg: EngineMessage =
            serde_json::from_str(r#"{"v":1,"type":"pong","id":"01J5","extra_field":"future"}"#)
                .unwrap();
        assert_eq!(msg, EngineMessage::pong("01J5"));
    }

    #[test]
    fn unknown_error_code_decodes_to_unknown() {
        let msg: EngineMessage = serde_json::from_str(
            r#"{"v":1,"type":"error","code":"flux_capacitor_misaligned","message":"x","fatal":false}"#,
        )
        .unwrap();
        match msg {
            EngineMessage::Error {
                code, session_id, ..
            } => {
                assert_eq!(code, ErrorCode::Unknown);
                assert_eq!(session_id, None);
            }
            other => panic!("expected error, got {other:?}"),
        }
    }

    #[test]
    fn error_without_session_id_omits_the_field() {
        let msg = EngineMessage::error(ErrorCode::Internal, "boom", true);
        let val = serde_json::to_value(&msg).unwrap();
        assert_eq!(
            val,
            json!({"v":1,"type":"error","code":"internal","message":"boom","fatal":true})
        );
    }

    #[test]
    fn every_error_code_round_trips_to_snake_case() {
        for (code, wire) in [
            (ErrorCode::TccDeniedMic, "\"tcc_denied_mic\""),
            (ErrorCode::TccDeniedSystem, "\"tcc_denied_system\""),
            (ErrorCode::TapFailed, "\"tap_failed\""),
            (ErrorCode::DeviceGone, "\"device_gone\""),
            (ErrorCode::ModelDownloadFailed, "\"model_download_failed\""),
            (ErrorCode::SessionAlreadyActive, "\"session_already_active\""),
            (ErrorCode::NoActiveSession, "\"no_active_session\""),
            (ErrorCode::BadRequest, "\"bad_request\""),
            (ErrorCode::Internal, "\"internal\""),
        ] {
            assert_eq!(serde_json::to_string(&code).unwrap(), wire);
            assert_eq!(serde_json::from_str::<ErrorCode>(wire).unwrap(), code);
        }
    }
}
