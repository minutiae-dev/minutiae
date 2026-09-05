//! Phase 1 stub ASR backend.
//!
//! Reports models as ready and returns empty transcriptions, so the handshake,
//! device-listing, and liveness paths can be validated before the sherpa-onnx
//! backend lands in Phase 2. Advertises the default engine id (the multilingual
//! Nemotron model the core selects by default) so the hello_ack `engine_versions`
//! match the macOS twin; Phase 2 will run Nemotron-3.5 streaming via sherpa-onnx
//! (see `docs/windows-port.md`).

use super::{AsrEngine, AsrResult};

/// Wire engine id of the default model, mirroring macOS `NemotronEngine`.
pub const ENGINE_ID: &str = "nemotron-streaming-ml";

#[derive(Debug, Default)]
pub struct StubAsrEngine;

impl StubAsrEngine {
    pub fn new() -> Self {
        Self
    }
}

impl AsrEngine for StubAsrEngine {
    fn id(&self) -> &str {
        ENGINE_ID
    }

    fn version(&self) -> String {
        // Distinct from any real model rev so a stub build is obvious in logs.
        format!("stub-{}", env!("CARGO_PKG_VERSION"))
    }

    fn models_cached(&self) -> bool {
        true
    }

    fn prepare(&self, progress: &mut dyn FnMut(f64, &str)) -> Result<(), String> {
        progress(1.0, "compiling");
        Ok(())
    }

    fn transcribe(&self, _window: &[f32], _sample_rate: u32) -> Result<AsrResult, String> {
        Ok(AsrResult::default())
    }
}
