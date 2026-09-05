//! LLM sidecar IPC protocol v1 — hand-mirrored from `docs/protocol/llm-ipc-v1.md`.
//!
//! The doc is the source of truth. The Swift twin lives at
//! `llm-engine/Sources/minutiae-llm/IPC/Messages.swift`. Change all three together.
//!
//! Transport is NDJSON: requests core → llm on stdin, responses/events
//! llm → core on stdout. Every message carries `"v": 1` and a snake_case
//! `"type"`. Receivers ignore unknown fields and unknown message types.

use serde::{Deserialize, Serialize};

pub const LLM_PROTOCOL_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// Core → llm

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LlmCoreMessage {
    /// First message after spawn.
    Hello { v: u32, id: String },
    /// Optional pre-warm: download (if needed) and load a model.
    PrepareModel { v: u32, id: String, model: String },
    /// Run one streamed completion. Loads `model` on demand.
    Enhance {
        v: u32,
        id: String,
        model: String,
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        system: Option<String>,
        #[serde(default)]
        options: EnhanceOptions,
    },
    /// Stop the in-flight `enhance` whose id is `request_id`.
    Cancel {
        v: u32,
        id: String,
        request_id: String,
    },
    /// Health check.
    Ping { v: u32, id: String },
    /// Graceful exit; equivalent to stdin EOF.
    Shutdown { v: u32 },
}

impl LlmCoreMessage {
    pub fn hello(id: impl Into<String>) -> Self {
        Self::Hello {
            v: LLM_PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    pub fn prepare_model(id: impl Into<String>, model: impl Into<String>) -> Self {
        Self::PrepareModel {
            v: LLM_PROTOCOL_VERSION,
            id: id.into(),
            model: model.into(),
        }
    }

    pub fn enhance(
        id: impl Into<String>,
        model: impl Into<String>,
        prompt: impl Into<String>,
        system: Option<String>,
        options: EnhanceOptions,
    ) -> Self {
        Self::Enhance {
            v: LLM_PROTOCOL_VERSION,
            id: id.into(),
            model: model.into(),
            prompt: prompt.into(),
            system,
            options,
        }
    }

    pub fn cancel(id: impl Into<String>, request_id: impl Into<String>) -> Self {
        Self::Cancel {
            v: LLM_PROTOCOL_VERSION,
            id: id.into(),
            request_id: request_id.into(),
        }
    }

    pub fn ping(id: impl Into<String>) -> Self {
        Self::Ping {
            v: LLM_PROTOCOL_VERSION,
            id: id.into(),
        }
    }

    pub fn shutdown() -> Self {
        Self::Shutdown {
            v: LLM_PROTOCOL_VERSION,
        }
    }

    pub fn id(&self) -> Option<&str> {
        match self {
            Self::Hello { id, .. }
            | Self::PrepareModel { id, .. }
            | Self::Enhance { id, .. }
            | Self::Cancel { id, .. }
            | Self::Ping { id, .. } => Some(id),
            Self::Shutdown { .. } => None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EnhanceOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Qwen3.5 is a reasoning model; `false` (default) suppresses the `<think>`
    /// block via `/no_think` for enhancement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enable_thinking: Option<bool>,
}

// ---------------------------------------------------------------------------
// llm → core

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LlmMessage {
    HelloAck {
        v: u32,
        id: String,
        protocol_version: u32,
        /// e.g. "mlx"
        runtime: String,
        /// Model id currently resident, or None.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loaded_model: Option<String>,
    },
    /// Emitted while a model downloads/loads.
    ModelProgress { v: u32, pct: f64, stage: ModelStage },
    /// Correlated response to `prepare_model`.
    ModelReady { v: u32, id: String, model: String },
    /// A streamed chunk of generated text for `enhance` request `id`.
    LlmToken { v: u32, id: String, text: String },
    /// Terminal for an `enhance`.
    LlmDone {
        v: u32,
        id: String,
        finish_reason: FinishReason,
        stats: Stats,
    },
    Error {
        v: u32,
        code: LlmErrorCode,
        message: String,
        fatal: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },
    Pong { v: u32, id: String },
    /// Forward compatibility: unknown message types must not kill the reader.
    #[serde(other)]
    Unknown,
}

impl LlmMessage {
    /// The echoed request id, if this message type carries one.
    pub fn id(&self) -> Option<&str> {
        match self {
            Self::HelloAck { id, .. }
            | Self::ModelReady { id, .. }
            | Self::LlmToken { id, .. }
            | Self::LlmDone { id, .. }
            | Self::Pong { id, .. } => Some(id),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Stats {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub duration_ms: u64,
    pub tokens_per_s: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FinishReason {
    Stop,
    Length,
    Cancelled,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelStage {
    Downloading,
    Loading,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LlmErrorCode {
    ModelDownloadFailed,
    ModelLoadFailed,
    GenerationFailed,
    BadRequest,
    Internal,
    #[serde(other)]
    Unknown,
}

// ---------------------------------------------------------------------------
// Tests: round-trips for every message type + exact wire shapes from the doc.

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn rt_core(msg: LlmCoreMessage) {
        let wire = serde_json::to_string(&msg).unwrap();
        let back: LlmCoreMessage = serde_json::from_str(&wire).unwrap();
        assert_eq!(msg, back, "core round-trip failed for {wire}");
    }

    fn rt_llm(msg: LlmMessage) {
        let wire = serde_json::to_string(&msg).unwrap();
        let back: LlmMessage = serde_json::from_str(&wire).unwrap();
        assert_eq!(msg, back, "llm round-trip failed for {wire}");
    }

    #[test]
    fn round_trip_every_core_message() {
        rt_core(LlmCoreMessage::hello("01J1"));
        rt_core(LlmCoreMessage::prepare_model("01J2", "mlx-community/Qwen3.5-4B-MLX-4bit"));
        rt_core(LlmCoreMessage::enhance(
            "01J3",
            "mlx-community/Qwen3.5-4B-MLX-4bit",
            "Summarize the meeting.",
            Some("You are a precise meeting summarizer.".into()),
            EnhanceOptions {
                max_tokens: Some(1024),
                temperature: Some(0.6),
                enable_thinking: Some(false),
            },
        ));
        rt_core(LlmCoreMessage::cancel("01J4", "01J3"));
        rt_core(LlmCoreMessage::ping("01J5"));
        rt_core(LlmCoreMessage::shutdown());
    }

    #[test]
    fn round_trip_every_llm_message() {
        rt_llm(LlmMessage::HelloAck {
            v: 1,
            id: "01J1".into(),
            protocol_version: 1,
            runtime: "mlx".into(),
            loaded_model: Some("mlx-community/Qwen3.5-4B-MLX-4bit".into()),
        });
        rt_llm(LlmMessage::ModelProgress {
            v: 1,
            pct: 42.5,
            stage: ModelStage::Downloading,
        });
        rt_llm(LlmMessage::ModelReady {
            v: 1,
            id: "01J2".into(),
            model: "mlx-community/Qwen3.5-4B-MLX-4bit".into(),
        });
        rt_llm(LlmMessage::LlmToken {
            v: 1,
            id: "01J3".into(),
            text: "Local-first ".into(),
        });
        rt_llm(LlmMessage::LlmDone {
            v: 1,
            id: "01J3".into(),
            finish_reason: FinishReason::Stop,
            stats: Stats {
                prompt_tokens: 4120,
                completion_tokens: 86,
                duration_ms: 5100,
                tokens_per_s: 16.9,
            },
        });
        rt_llm(LlmMessage::Error {
            v: 1,
            code: LlmErrorCode::GenerationFailed,
            message: "boom".into(),
            fatal: false,
            request_id: Some("01J3".into()),
        });
        rt_llm(LlmMessage::Pong {
            v: 1,
            id: "01J5".into(),
        });
    }

    #[test]
    fn wire_shape_enhance_matches_swift() {
        // Exactly what minutiae-llm decodes (system + options present).
        let wire = r#"{
            "v": 1, "type": "enhance", "id": "01J3",
            "model": "mlx-community/Qwen3.5-4B-MLX-4bit",
            "prompt": "Summarize.",
            "system": "You are a summarizer.",
            "options": {"max_tokens": 1024, "temperature": 0.6, "enable_thinking": false}
        }"#;
        let msg: LlmCoreMessage = serde_json::from_str(wire).unwrap();
        match &msg {
            LlmCoreMessage::Enhance { options, system, .. } => {
                assert_eq!(options.max_tokens, Some(1024));
                assert_eq!(options.enable_thinking, Some(false));
                assert_eq!(system.as_deref(), Some("You are a summarizer."));
            }
            other => panic!("expected enhance, got {other:?}"),
        }
        // re-serialize and reparse equals
        let back: LlmCoreMessage =
            serde_json::from_str(&serde_json::to_string(&msg).unwrap()).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn enhance_without_system_or_options_defaults() {
        let wire = r#"{"v":1,"type":"enhance","id":"x","model":"m","prompt":"p"}"#;
        let msg: LlmCoreMessage = serde_json::from_str(wire).unwrap();
        match msg {
            LlmCoreMessage::Enhance { system, options, .. } => {
                assert!(system.is_none());
                assert_eq!(options, EnhanceOptions::default());
            }
            other => panic!("expected enhance, got {other:?}"),
        }
    }

    #[test]
    fn wire_shape_llm_token_and_done() {
        let token: LlmMessage =
            serde_json::from_str(r#"{"v":1,"type":"llm_token","id":"01J3","text":"hi"}"#).unwrap();
        assert_eq!(
            token,
            LlmMessage::LlmToken {
                v: 1,
                id: "01J3".into(),
                text: "hi".into()
            }
        );
        let done: LlmMessage = serde_json::from_str(
            r#"{"v":1,"type":"llm_done","id":"01J3","finish_reason":"cancelled",
                "stats":{"prompt_tokens":0,"completion_tokens":0,"duration_ms":0,"tokens_per_s":0.0}}"#,
        )
        .unwrap();
        match done {
            LlmMessage::LlmDone { finish_reason, .. } => {
                assert_eq!(finish_reason, FinishReason::Cancelled)
            }
            other => panic!("expected llm_done, got {other:?}"),
        }
    }

    #[test]
    fn hello_ack_without_loaded_model_omits_field() {
        let msg = LlmMessage::HelloAck {
            v: 1,
            id: "h".into(),
            protocol_version: 1,
            runtime: "mlx".into(),
            loaded_model: None,
        };
        let val = serde_json::to_value(&msg).unwrap();
        assert_eq!(
            val,
            json!({"v":1,"type":"hello_ack","id":"h","protocol_version":1,"runtime":"mlx"})
        );
    }

    #[test]
    fn unknown_llm_type_decodes_to_unknown() {
        let msg: LlmMessage =
            serde_json::from_str(r#"{"v":1,"type":"telemetry","blob":1}"#).unwrap();
        assert_eq!(msg, LlmMessage::Unknown);
    }

    #[test]
    fn unknown_enums_decode_to_unknown_not_error() {
        let v: Value = serde_json::from_str(
            r#"{"v":1,"type":"error","code":"flux","message":"x","fatal":false}"#,
        )
        .unwrap();
        let msg: LlmMessage = serde_json::from_value(v).unwrap();
        match msg {
            LlmMessage::Error { code, .. } => assert_eq!(code, LlmErrorCode::Unknown),
            other => panic!("expected error, got {other:?}"),
        }
    }
}
