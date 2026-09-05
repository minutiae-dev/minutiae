//! Events emitted to the window, and their payload shapes.
//!
//! The TypeScript twin lives in `app/src/lib/ipc.ts` — change both together.

use serde::Serialize;

use crate::protocol::{ErrorCode, Segment};
use crate::session::Phase;

pub const SESSION_STATE: &str = "session:state";
pub const TRANSCRIPT_SEGMENT: &str = "transcript:segment";
pub const LEVELS_UPDATE: &str = "levels:update";
pub const MODEL_PROGRESS: &str = "model:progress";
pub const MODEL_READY: &str = "model:ready";
pub const APP_ERROR: &str = "app:error";

// Enhancement (M2) — the LLM sidecar streams a completion for the focused
// session; the core accumulates it and writes `<Title>.md` to the vault.
pub const LLM_PROGRESS: &str = "llm:progress";
pub const LLM_TOKEN: &str = "llm:token";
pub const LLM_DONE: &str = "llm:done";
pub const LLM_ERROR: &str = "llm:error";
// On-demand LLM model download/load (user-triggered, never at launch).
pub const LLM_MODEL_PROGRESS: &str = "llm:model_progress";
pub const LLM_MODEL_READY: &str = "llm:model_ready";

#[derive(Debug, Clone, Serialize)]
pub struct SessionStatePayload {
    pub state: Phase,
    pub session_id: Option<String>,
    /// Wall-clock anchor for session-relative seconds; None until recording.
    pub t0_epoch_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TranscriptSegmentPayload {
    pub session_id: String,
    pub segment: Segment,
}

#[derive(Debug, Clone, Serialize)]
pub struct LevelsPayload {
    pub me_db: f64,
    pub them_db: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelProgressPayload {
    pub pct: f64,
    pub stage: String,
}

/// Fired once the ASR models finish downloading/compiling at launch. The UI
/// gates recording until this arrives (or `get_state().models_ready` is true).
#[derive(Debug, Clone, Serialize)]
pub struct ModelReadyPayload {
    pub ready: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct AppErrorPayload {
    pub code: ErrorCode,
    pub message: String,
    pub fatal: bool,
}

/// Model load progress during enhancement (first-run download / load).
#[derive(Debug, Clone, Serialize)]
pub struct LlmProgressPayload {
    pub pct: f64,
    /// "downloading" | "loading"
    pub stage: String,
}

/// One streamed chunk of the enhanced note; concatenate in arrival order.
#[derive(Debug, Clone, Serialize)]
pub struct LlmTokenPayload {
    pub text: String,
}

/// Enhancement finished and the Markdown file was written to the vault.
#[derive(Debug, Clone, Serialize)]
pub struct LlmDonePayload {
    /// Absolute path of the written `<Title>.md`.
    pub path: String,
    /// Display name of the file (for a compact toast).
    pub file: String,
    pub tokens_per_s: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct LlmErrorPayload {
    pub message: String,
}

/// Fired when the on-demand LLM model download/load finishes.
#[derive(Debug, Clone, Serialize)]
pub struct LlmModelReadyPayload {
    pub ready: bool,
}

/// Response shape of the `get_llm_status` command.
#[derive(Debug, Clone, Serialize)]
pub struct LlmStatusPayload {
    /// Weights are on disk (enhancing won't trigger a multi-GB download).
    pub downloaded: bool,
    /// Model is loaded into the sidecar this session.
    pub ready: bool,
    /// Cloud enrichment is the active transport (SaaS, signed in, cloud chosen),
    /// so enhancing needs no local model. Always false in OSS builds.
    pub cloud_active: bool,
}

/// Response shape of the `get_state` command (a superset of
/// [`SessionStatePayload`]).
#[derive(Debug, Clone, Serialize)]
pub struct AppStateSnapshot {
    pub state: Phase,
    pub session_id: Option<String>,
    pub t0_epoch_ms: Option<u64>,
    pub models_ready: bool,
}
