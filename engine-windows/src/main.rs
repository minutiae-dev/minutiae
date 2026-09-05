//! `minutiae-engine` — the Windows audio/ASR sidecar.
//!
//! A protocol twin of the macOS Swift engine (`engine/`): it speaks the same
//! NDJSON `sidecar-ipc-v1` protocol over stdio so the Rust core spawns it
//! unchanged. Phase 1 implements the IPC seam (handshake, liveness, device
//! enumeration); WASAPI capture + sherpa-onnx ASR follow in Phase 2.
//!
//! Design and milestone: `docs/windows-port.md`, M6 in `docs/milestones.md`.

// Some IPC/clock/ASR scaffolding (request-id correlation, `SessionClock`,
// `AsrResult` fields) is wired up here but only consumed once Phase 2 adds
// capture + the sherpa-onnx backend. Keep it to avoid churn between phases.
#![allow(dead_code)]

mod asr;
mod capture;
mod controller;
mod ipc;
mod util;

use controller::EngineController;

fn main() {
    util::log("starting (sidecar-ipc-v1, Phase 1: IPC seam)");
    EngineController::new().run();
    util::log("exited cleanly");
}
