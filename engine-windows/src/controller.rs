//! Engine controller: the message dispatch loop.
//!
//! Mirrors the Swift `EngineController`. Two threads:
//!
//! - the **reader thread** (owned by [`Transport`]) decodes core→engine lines.
//!   `ping` is answered with `pong` **inline on the reader thread** so liveness
//!   is proven regardless of how backed-up the work loop is (the core kills the
//!   process after 2 missed pongs). Everything else is queued.
//! - the **worker** drains that queue **serially**, so session state needs no
//!   extra locking.
//!
//! EOF on stdin (parent gone) and an explicit `shutdown` both end the loop and
//! exit cleanly.

use std::sync::mpsc::{self};

use crate::asr::{AsrEngine, StubAsrEngine};
use crate::capture::devices;
use crate::ipc::messages::{CoreMessage, EngineMessage, ErrorCode, PROTOCOL_VERSION};
use crate::ipc::transport::{Sender, Transport};
use crate::util::log;

enum WorkItem {
    Message(CoreMessage),
    Eof,
}

#[derive(Default)]
pub struct EngineController;

impl EngineController {
    pub fn new() -> Self {
        Self
    }

    /// Run until `shutdown` or stdin EOF, then return (the process exits 0).
    pub fn run(self) {
        let transport = Transport::new();
        let out = transport.sender();
        let (tx, rx) = mpsc::channel::<WorkItem>();

        // Reader thread: answer pings immediately, queue everything else.
        let ping_out = out.clone();
        let tx_msg = tx.clone();
        transport.start(
            move |msg| match msg {
                CoreMessage::Ping { id, .. } => ping_out.send(&EngineMessage::pong(id)),
                other => {
                    // If the worker is gone the send fails harmlessly.
                    let _ = tx_msg.send(WorkItem::Message(other));
                }
            },
            move || {
                let _ = tx.send(WorkItem::Eof);
            },
        );

        // Worker: serial processing on this (main) thread.
        let engine = StubAsrEngine::new();
        for item in rx {
            match item {
                WorkItem::Eof => {
                    log("stdin closed; shutting down");
                    break;
                }
                WorkItem::Message(msg) => {
                    if self.handle(&out, &engine, msg) {
                        break;
                    }
                }
            }
        }
    }

    /// Handle one message. Returns `true` to stop the loop (shutdown).
    fn handle<E: AsrEngine>(&self, out: &Sender, engine: &E, msg: CoreMessage) -> bool {
        match msg {
            CoreMessage::Hello { id, .. } => {
                let mut versions = std::collections::BTreeMap::new();
                versions.insert(engine.id().to_string(), engine.version());
                out.send(&EngineMessage::HelloAck {
                    v: PROTOCOL_VERSION,
                    id,
                    protocol_version: PROTOCOL_VERSION,
                    engine_versions: versions,
                    models_ready: engine.models_cached(),
                });
            }

            CoreMessage::PrepareModels { id, .. } => {
                // Pings are answered on the reader thread, so even a slow
                // prepare here won't starve liveness. (Stub completes instantly.)
                let mut emit_progress = |pct: f64, stage: &str| {
                    out.send(&EngineMessage::ModelProgress {
                        v: PROTOCOL_VERSION,
                        pct: pct * 100.0,
                        stage: stage.to_string(),
                    });
                };
                match engine.prepare(&mut emit_progress) {
                    Ok(()) => out.send(&EngineMessage::models_ready(id)),
                    Err(e) => {
                        out.send(&EngineMessage::error(ErrorCode::ModelDownloadFailed, e, false))
                    }
                }
            }

            CoreMessage::ListDevices { id, .. } => match devices::list_input_devices() {
                Ok(items) => out.send(&EngineMessage::Devices {
                    v: PROTOCOL_VERSION,
                    id,
                    items,
                }),
                Err(e) => out.send(&EngineMessage::error(ErrorCode::Internal, e, false)),
            },

            // Capture lands in Phase 2. Fail the start with a non-fatal error
            // tied to the session id; the core fails the start op fast on any
            // `error` event (no id needed).
            CoreMessage::StartSession { session_id, .. } => {
                out.send(&EngineMessage::session_error(
                    ErrorCode::Internal,
                    "audio capture not implemented in this build (Phase 1: IPC seam only)",
                    false,
                    session_id,
                ));
            }

            CoreMessage::StopSession { .. } => {
                out.send(&EngineMessage::error(
                    ErrorCode::NoActiveSession,
                    "no active session",
                    false,
                ));
            }

            // Normally answered on the reader thread; handle here too for safety
            // if one ever reaches the worker queue.
            CoreMessage::Ping { id, .. } => out.send(&EngineMessage::pong(id)),

            CoreMessage::Shutdown { .. } => return true,
        }
        false
    }
}
