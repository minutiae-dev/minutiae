//! Sidecar process management: spawn, handshake, health, respawn, routing.
//!
//! A supervisor task owns the engine process lifecycle: spawn via
//! tauri-plugin-shell's sidecar API, `hello`/`hello_ack` handshake, then an
//! event loop that parses stdout NDJSON into [`EngineMessage`]s, pings every
//! 5 s (two missed pongs kill the process), and flushes the transcript on a
//! housekeeping tick. On engine death the supervisor aborts any active
//! session (partial transcript already flushed survives), emits `app:error`,
//! and respawns with capped exponential backoff (1 s, 2 s, 4 s, … max 10 s).
//!
//! Lock discipline: `engine` and `session` are separate std mutexes; they are
//! never held across an await and never nested.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::oneshot;

use crate::events;
use crate::protocol::{CoreMessage, DeviceInfo, EngineMessage, ErrorCode};
use crate::session::{MicInfo, Phase, SessionMachine};

pub const SIDECAR_NAME: &str = "minutiae-engine";
pub const DEFAULT_ENGINE: &str = "parakeet-tdt-v3";
pub const DEFAULT_LANGUAGE: &str = "en";

const PING_INTERVAL: Duration = Duration::from_secs(5);
const MAX_MISSED_PONGS: u32 = 2;
const HOUSEKEEPING_INTERVAL: Duration = Duration::from_secs(2);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// First run may download/compile models before capture can begin; the UI
/// shows `model_progress` meanwhile.
const START_TIMEOUT: Duration = Duration::from_secs(180);
/// Stop includes the Opus transcode of potentially hours of audio.
const STOP_TIMEOUT: Duration = Duration::from_secs(120);
const BACKOFF_INITIAL: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(10);

#[derive(Debug, thiserror::Error)]
pub enum SidecarError {
    #[error("engine is not running")]
    NotRunning,
    #[error("engine request timed out")]
    Timeout,
    #[error("engine restarted while waiting for a response")]
    EngineRestarted,
    #[error("engine error ({code:?}): {message}")]
    Engine { code: ErrorCode, message: String },
    #[error("unexpected response from engine")]
    UnexpectedResponse,
    #[error("{0}")]
    Session(#[from] crate::session::SessionError),
    #[error("serialization error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("shell error: {0}")]
    Shell(String),
    #[error("{0}")]
    Other(String),
}

/// Mutable state tied to the *current* engine process.
#[derive(Default)]
struct EngineLink {
    child: Option<CommandChild>,
    pending: HashMap<String, oneshot::Sender<EngineMessage>>,
    /// Request id of the in-flight start/stop operation, so id-less `error`
    /// events can fail it fast instead of letting it time out.
    current_op: Option<String>,
    outstanding_pings: u32,
    models_ready: bool,
}

struct Shared {
    app: AppHandle,
    engine: Mutex<EngineLink>,
    session: Mutex<SessionMachine>,
    devices: Mutex<Vec<DeviceInfo>>,
}

/// Managed by tauri state; cheap to clone handles out of.
pub struct SidecarManager {
    shared: Arc<Shared>,
}

impl SidecarManager {
    pub fn new(app: AppHandle) -> Self {
        Self {
            shared: Arc::new(Shared {
                app,
                engine: Mutex::new(EngineLink::default()),
                session: Mutex::new(SessionMachine::new(env!("CARGO_PKG_VERSION"))),
                devices: Mutex::new(Vec::new()),
            }),
        }
    }

    /// Spawn the supervisor task (call once from setup).
    pub fn start(&self) {
        let shared = self.shared.clone();
        tauri::async_runtime::spawn(supervisor(shared));
    }

    // -- Command surface ----------------------------------------------------

    pub async fn list_devices(&self) -> Result<Vec<DeviceInfo>, SidecarError> {
        let msg = CoreMessage::list_devices(new_id());
        match request(&self.shared, msg, REQUEST_TIMEOUT, false).await? {
            EngineMessage::Devices { items, .. } => {
                *self.shared.devices.lock().unwrap() = items.clone();
                Ok(items)
            }
            EngineMessage::Error { code, message, .. } => {
                Err(SidecarError::Engine { code, message })
            }
            _ => Err(SidecarError::UnexpectedResponse),
        }
    }

    pub async fn start_session(
        &self,
        mic_uid: String,
    ) -> Result<events::SessionStatePayload, SidecarError> {
        let shared = &self.shared;
        let mic = self.resolve_mic(&mic_uid).await;
        let sessions_root = sessions_root(&shared.app)?;

        let start = {
            let mut session = shared.session.lock().unwrap();
            session.begin_starting(&sessions_root, mic, DEFAULT_ENGINE, DEFAULT_LANGUAGE)?
        };
        emit_session_state(shared);
        tracing::info!(session_id = %start.session_id, dir = %start.dir.display(), "starting session");

        let msg = CoreMessage::start_session(
            new_id(),
            start.session_id.clone(),
            start.dir.to_string_lossy(),
            mic_uid,
            DEFAULT_ENGINE,
            DEFAULT_LANGUAGE,
        );
        let result = request(shared, msg, START_TIMEOUT, true).await;
        match result {
            Ok(EngineMessage::SessionStarted { t0_epoch_ms, .. }) => {
                {
                    let mut session = shared.session.lock().unwrap();
                    session.mark_recording(t0_epoch_ms)?;
                }
                tracing::info!(session_id = %start.session_id, t0_epoch_ms, "session recording");
                Ok(emit_session_state(shared))
            }
            Ok(EngineMessage::Error { code, message, .. }) => {
                self.fail_active(&start.dir);
                Err(SidecarError::Engine { code, message })
            }
            Ok(_) => {
                self.fail_active(&start.dir);
                Err(SidecarError::UnexpectedResponse)
            }
            Err(e) => {
                self.fail_active(&start.dir);
                Err(e)
            }
        }
    }

    pub async fn stop_session(&self) -> Result<events::SessionStatePayload, SidecarError> {
        let shared = &self.shared;
        {
            let mut session = shared.session.lock().unwrap();
            session.begin_stopping()?;
        }
        emit_session_state(shared);

        let msg = CoreMessage::stop_session(new_id());
        match request(shared, msg, STOP_TIMEOUT, true).await {
            Ok(EngineMessage::SessionStopped {
                session_id,
                audio,
                stats,
                ..
            }) => {
                let finalized = {
                    let mut session = shared.session.lock().unwrap();
                    session.finalize(&audio, Utc::now())
                };
                match finalized {
                    Ok(done) => {
                        tracing::info!(
                            session_id = %session_id,
                            segments = done.segments,
                            engine_segments = stats.segments,
                            dropped_windows = stats.dropped_windows,
                            duration_s = done.duration_s,
                            dir = %done.dir.display(),
                            "session stopped"
                        );
                        Ok(emit_session_state(shared))
                    }
                    Err(e) => {
                        self.fail_active_no_cleanup();
                        Err(e.into())
                    }
                }
            }
            Ok(EngineMessage::Error { code, message, .. }) => {
                self.fail_active_no_cleanup();
                Err(SidecarError::Engine { code, message })
            }
            Ok(_) => {
                self.fail_active_no_cleanup();
                Err(SidecarError::UnexpectedResponse)
            }
            Err(e) => {
                self.fail_active_no_cleanup();
                Err(e)
            }
        }
    }

    pub fn snapshot(&self) -> events::AppStateSnapshot {
        let (state, session_id, t0_epoch_ms) = {
            let session = self.shared.session.lock().unwrap();
            (
                session.phase(),
                session.session_id().map(str::to_string),
                session.t0_epoch_ms(),
            )
        };
        let models_ready = self.shared.engine.lock().unwrap().models_ready;
        events::AppStateSnapshot {
            state,
            session_id,
            t0_epoch_ms,
            models_ready,
        }
    }

    // -- Internals ----------------------------------------------------------

    /// Look up mic metadata from the cached device list, refreshing it once
    /// if needed. Falls back to the bare uid so a stale cache never blocks
    /// session start.
    async fn resolve_mic(&self, mic_uid: &str) -> MicInfo {
        let find = |devices: &[DeviceInfo]| {
            devices.iter().find(|d| d.uid == mic_uid).map(|d| MicInfo {
                uid: d.uid.clone(),
                name: d.name.clone(),
                sample_rate: d.sample_rate,
            })
        };
        if let Some(found) = find(&self.shared.devices.lock().unwrap()) {
            return found;
        }
        if let Ok(items) = self.list_devices().await {
            if let Some(found) = find(&items) {
                return found;
            }
        }
        MicInfo {
            uid: mic_uid.to_string(),
            name: mic_uid.to_string(),
            sample_rate: 0,
        }
    }

    /// Abort a session that failed to start; removes the (empty) folder.
    fn fail_active(&self, dir: &PathBuf) {
        {
            let mut session = self.shared.session.lock().unwrap();
            session.abort();
        }
        // best effort: only removes the folder if nothing was written into it
        let _ = std::fs::remove_dir(dir);
        emit_session_state(&self.shared);
    }

    /// Abort a session that failed mid/stop; keeps whatever is on disk.
    fn fail_active_no_cleanup(&self) {
        {
            let mut session = self.shared.session.lock().unwrap();
            session.abort();
        }
        emit_session_state(&self.shared);
    }
}

fn new_id() -> String {
    ulid::Ulid::new().to_string()
}

fn sessions_root(app: &AppHandle) -> Result<PathBuf, SidecarError> {
    // ~/Library/Application Support/Minutiae/sessions (docs/session-format.md)
    let data_dir = app
        .path()
        .data_dir()
        .map_err(|e| SidecarError::Other(format!("cannot resolve data dir: {e}")))?;
    Ok(data_dir.join("Minutiae").join("sessions"))
}

/// Emit the current session state to the UI and return the payload.
fn emit_session_state(shared: &Arc<Shared>) -> events::SessionStatePayload {
    let payload = {
        let session = shared.session.lock().unwrap();
        events::SessionStatePayload {
            state: session.phase(),
            session_id: session.session_id().map(str::to_string),
            t0_epoch_ms: session.t0_epoch_ms(),
        }
    };
    if let Err(e) = shared.app.emit(events::SESSION_STATE, payload.clone()) {
        tracing::warn!("failed to emit session state: {e}");
    }
    payload
}

fn emit_app_error(shared: &Shared, code: ErrorCode, message: String, fatal: bool) {
    let _ = shared.app.emit(
        events::APP_ERROR,
        events::AppErrorPayload {
            code,
            message,
            fatal,
        },
    );
}

/// Send a request line to the engine and await its correlated response.
async fn request(
    shared: &Arc<Shared>,
    msg: CoreMessage,
    timeout: Duration,
    is_op: bool,
) -> Result<EngineMessage, SidecarError> {
    let id = msg
        .id()
        .expect("requests must carry an id")
        .to_string();
    let (tx, rx) = oneshot::channel();
    {
        let mut engine = shared.engine.lock().unwrap();
        let child = engine.child.as_mut().ok_or(SidecarError::NotRunning)?;
        let mut line = serde_json::to_vec(&msg)?;
        line.push(b'\n');
        child
            .write(&line)
            .map_err(|e| SidecarError::Shell(e.to_string()))?;
        engine.pending.insert(id.clone(), tx);
        if is_op {
            engine.current_op = Some(id.clone());
        }
    }

    let result = tokio::time::timeout(timeout, rx).await;

    {
        let mut engine = shared.engine.lock().unwrap();
        engine.pending.remove(&id);
        if engine.current_op.as_deref() == Some(id.as_str()) {
            engine.current_op = None;
        }
    }

    match result {
        Ok(Ok(reply)) => Ok(reply),
        // sender dropped: the engine died and pending was cleared
        Ok(Err(_)) => Err(SidecarError::EngineRestarted),
        Err(_) => Err(SidecarError::Timeout),
    }
}

// ---------------------------------------------------------------------------
// Supervisor

async fn supervisor(shared: Arc<Shared>) {
    let mut backoff = BACKOFF_INITIAL;
    loop {
        let mut handshake_ok = false;
        let outcome = run_engine(&shared, &mut handshake_ok).await;
        match &outcome {
            Ok(()) => tracing::warn!("engine exited"),
            Err(e) => tracing::warn!("engine failed: {e}"),
        }
        on_engine_down(&shared);

        if handshake_ok {
            backoff = BACKOFF_INITIAL;
        }
        tracing::info!("respawning engine in {backoff:?}");
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// One engine process lifetime: spawn → handshake → event loop. Returns when
/// the process dies or is declared dead (missed pongs / handshake timeout).
async fn run_engine(shared: &Arc<Shared>, handshake_ok: &mut bool) -> Result<(), String> {
    let command = shared
        .app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|e| format!("sidecar command: {e}"))?;
    let (mut rx, child) = command.spawn().map_err(|e| format!("spawn: {e}"))?;
    let pid = child.pid();
    tracing::info!(pid, "engine spawned");

    {
        let mut engine = shared.engine.lock().unwrap();
        engine.child = Some(child);
        engine.outstanding_pings = 0;
        engine.models_ready = false;
    }

    // hello/hello_ack handshake, answered inside the event loop below
    let hello_id = new_id();
    send_line(shared, &CoreMessage::hello(hello_id.clone()))
        .map_err(|e| format!("hello: {e}"))?;

    let mut hello_done = false;
    let handshake_deadline = tokio::time::sleep(HANDSHAKE_TIMEOUT);
    tokio::pin!(handshake_deadline);

    let mut ping_tick = tokio::time::interval(PING_INTERVAL);
    ping_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut housekeeping_tick = tokio::time::interval(HOUSEKEEPING_INTERVAL);
    housekeeping_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            event = rx.recv() => {
                match event {
                    Some(CommandEvent::Stdout(bytes)) => {
                        for line in bytes.split(|b| *b == b'\n') {
                            let line = trim_ascii(line);
                            if line.is_empty() {
                                continue;
                            }
                            match serde_json::from_slice::<EngineMessage>(line) {
                                Ok(msg) => {
                                    if !hello_done {
                                        if let EngineMessage::HelloAck {
                                            protocol_version,
                                            models_ready,
                                            ..
                                        } = &msg
                                        {
                                            hello_done = true;
                                            *handshake_ok = true;
                                            tracing::info!(
                                                protocol_version,
                                                models_ready,
                                                "engine handshake complete"
                                            );
                                        }
                                    }
                                    handle_message(shared, msg);
                                }
                                Err(e) => tracing::warn!(
                                    "undecodable engine line ({e}): {}",
                                    String::from_utf8_lossy(line)
                                ),
                            }
                        }
                    }
                    Some(CommandEvent::Stderr(bytes)) => {
                        let text = String::from_utf8_lossy(&bytes);
                        let text = text.trim_end();
                        if !text.is_empty() {
                            tracing::warn!(target: "minutiae::engine", "{text}");
                        }
                    }
                    Some(CommandEvent::Error(e)) => {
                        tracing::warn!("engine io error: {e}");
                    }
                    Some(CommandEvent::Terminated(payload)) => {
                        return Err(format!(
                            "engine terminated (code {:?}, signal {:?})",
                            payload.code, payload.signal
                        ));
                    }
                    Some(_) => {}
                    None => return Err("engine event channel closed".into()),
                }
            }
            _ = &mut handshake_deadline, if !hello_done => {
                kill_child(shared);
                return Err("engine handshake timed out".into());
            }
            _ = ping_tick.tick(), if hello_done => {
                let unresponsive = {
                    let mut engine = shared.engine.lock().unwrap();
                    if engine.outstanding_pings >= MAX_MISSED_PONGS {
                        true
                    } else {
                        engine.outstanding_pings += 1;
                        false
                    }
                };
                if unresponsive {
                    kill_child(shared);
                    return Err(format!("engine missed {MAX_MISSED_PONGS} pongs"));
                }
                if let Err(e) = send_line(shared, &CoreMessage::ping(new_id())) {
                    tracing::warn!("ping write failed: {e}");
                }
            }
            _ = housekeeping_tick.tick() => {
                let flush = {
                    let mut session = shared.session.lock().unwrap();
                    session.flush_if_due()
                };
                if let Err(e) = flush {
                    tracing::warn!("transcript flush failed: {e}");
                }
            }
        }
    }
}

fn send_line(shared: &Arc<Shared>, msg: &CoreMessage) -> Result<(), SidecarError> {
    let mut engine = shared.engine.lock().unwrap();
    let child = engine.child.as_mut().ok_or(SidecarError::NotRunning)?;
    let mut line = serde_json::to_vec(msg)?;
    line.push(b'\n');
    child
        .write(&line)
        .map_err(|e| SidecarError::Shell(e.to_string()))
}

fn kill_child(shared: &Arc<Shared>) {
    let child = shared.engine.lock().unwrap().child.take();
    if let Some(child) = child {
        if let Err(e) = child.kill() {
            tracing::warn!("failed to kill engine: {e}");
        }
    }
}

fn trim_ascii(mut bytes: &[u8]) -> &[u8] {
    while let [first, rest @ ..] = bytes {
        if first.is_ascii_whitespace() {
            bytes = rest;
        } else {
            break;
        }
    }
    while let [rest @ .., last] = bytes {
        if last.is_ascii_whitespace() {
            bytes = rest;
        } else {
            break;
        }
    }
    bytes
}

/// Route one engine message: correlate responses, update session state,
/// forward UI events.
fn handle_message(shared: &Arc<Shared>, msg: EngineMessage) {
    match msg {
        EngineMessage::Pong { .. } => {
            shared.engine.lock().unwrap().outstanding_pings = 0;
        }
        EngineMessage::HelloAck { models_ready, .. } => {
            shared.engine.lock().unwrap().models_ready = models_ready;
        }
        EngineMessage::Transcript {
            session_id,
            segment,
            ..
        } => {
            {
                let mut session = shared.session.lock().unwrap();
                if let Err(e) = session.on_segment(&session_id, &segment) {
                    tracing::warn!("failed to persist segment: {e}");
                }
            }
            let _ = shared.app.emit(
                events::TRANSCRIPT_SEGMENT,
                events::TranscriptSegmentPayload {
                    session_id,
                    segment,
                },
            );
        }
        EngineMessage::Levels { me_db, them_db, .. } => {
            let _ = shared
                .app
                .emit(events::LEVELS_UPDATE, events::LevelsPayload { me_db, them_db });
        }
        EngineMessage::ModelProgress { pct, stage, .. } => {
            let _ = shared.app.emit(
                events::MODEL_PROGRESS,
                events::ModelProgressPayload { pct, stage },
            );
        }
        EngineMessage::Error {
            code,
            message,
            fatal,
            session_id,
            ..
        } => {
            tracing::warn!(?code, fatal, ?session_id, "engine error: {message}");
            // Error events carry no id; if a start/stop is in flight, fail it
            // now instead of letting it time out.
            let op_waiter = {
                let mut engine = shared.engine.lock().unwrap();
                engine
                    .current_op
                    .take()
                    .and_then(|op_id| engine.pending.remove(&op_id))
            };
            if let Some(tx) = op_waiter {
                let _ = tx.send(EngineMessage::Error {
                    v: crate::protocol::PROTOCOL_VERSION,
                    code,
                    message: message.clone(),
                    fatal,
                    session_id,
                });
            }
            emit_app_error(shared, code, message, fatal);
            // fatal: the engine will exit; Terminated handling respawns it.
        }
        msg @ (EngineMessage::Devices { .. }
        | EngineMessage::SessionStarted { .. }
        | EngineMessage::SessionStopped { .. }) => {
            let id = msg.id().expect("correlated responses carry an id").to_string();
            let waiter = shared.engine.lock().unwrap().pending.remove(&id);
            match waiter {
                Some(tx) => {
                    let _ = tx.send(msg);
                }
                None => tracing::warn!(id, "unsolicited response from engine: {msg:?}"),
            }
        }
        EngineMessage::Unknown => {
            tracing::debug!("ignoring unknown engine message type");
        }
    }
}

/// The engine died: clear per-process state, abort any active session
/// (partial transcript already flushed survives), tell the UI.
fn on_engine_down(shared: &Arc<Shared>) {
    {
        let mut engine = shared.engine.lock().unwrap();
        if let Some(child) = engine.child.take() {
            let _ = child.kill();
        }
        // dropping the senders fails in-flight requests with EngineRestarted
        engine.pending.clear();
        engine.current_op = None;
        engine.outstanding_pings = 0;
        engine.models_ready = false;
    }

    let aborted = {
        let mut session = shared.session.lock().unwrap();
        let had_session = !matches!(session.phase(), Phase::Idle | Phase::Error);
        let aborted = session.abort();
        had_session.then_some(aborted)
    };
    if let Some(aborted) = aborted {
        let detail = aborted
            .map(|a| format!(" Partial transcript saved in {}.", a.dir.display()))
            .unwrap_or_default();
        emit_app_error(
            shared,
            ErrorCode::Internal,
            format!("The transcription engine stopped; the session was aborted.{detail}"),
            false,
        );
        emit_session_state(shared);
    } else {
        emit_app_error(
            shared,
            ErrorCode::Internal,
            "The transcription engine stopped and is restarting.".to_string(),
            false,
        );
    }
}
