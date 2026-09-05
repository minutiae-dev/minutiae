//! ASR abstraction and its concrete backends.
//!
//! [`AsrEngine`] is the platform seam (mirrors the Swift `AsrEngine` protocol):
//! the controller and the windowed transcriber depend only on this trait, so a
//! different runtime (sherpa-onnx in Phase 2) slots in without touching the
//! orchestration. Phase 1 ships [`StubAsrEngine`] so the IPC seam can be
//! exercised without a model.

mod stub;

pub use stub::StubAsrEngine;

/// One transcribed window's result. `confidence` is 0..1, or `-1.0` if the
/// backend can't report it. (Token-level timings arrive with the real backend.)
#[derive(Debug, Clone, Default)]
pub struct AsrResult {
    pub text: String,
    pub confidence: f64,
}

/// On-device speech-to-text backend. Implementations must tolerate concurrent
/// `transcribe` callers (serialize internally) and a fresh decoder state per
/// window — overlap de-dup happens upstream in the windowed transcriber.
pub trait AsrEngine: Send + Sync {
    /// Stable engine id reported in `engine_versions` / `Segment.engine`.
    fn id(&self) -> &str;

    /// Backend/model revision string for `engine_versions`.
    fn version(&self) -> String;

    /// Whether the model is already present locally (drives `hello_ack.models_ready`
    /// without any network access).
    fn models_cached(&self) -> bool;

    /// Ensure models are downloaded/loaded. Idempotent. `progress(pct 0..1,
    /// stage)` streams to `model_progress`; `stage` is "downloading"|"compiling".
    /// Long work must run such that the caller can keep answering pings.
    fn prepare(&self, progress: &mut dyn FnMut(f64, &str)) -> Result<(), String>;

    /// Transcribe a 16 kHz mono f32 window. Phase 2.
    #[allow(dead_code)]
    fn transcribe(&self, window: &[f32], sample_rate: u32) -> Result<AsrResult, String>;
}
