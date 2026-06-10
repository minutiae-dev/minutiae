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
pub const APP_ERROR: &str = "app:error";

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

#[derive(Debug, Clone, Serialize)]
pub struct AppErrorPayload {
    pub code: ErrorCode,
    pub message: String,
    pub fatal: bool,
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
