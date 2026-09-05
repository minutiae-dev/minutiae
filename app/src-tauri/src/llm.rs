//! Local LLM enhancement: the `minutiae-llm` sidecar + the orchestration that
//! turns a finished session into a Markdown note in the user's vault.
//!
//! Two layers:
//!
//! - [`LlmBackend`] / [`LocalSidecar`] — the transport seam. `LocalSidecar`
//!   lazily spawns the `minutiae-llm` process (NDJSON over stdio, protocol
//!   `docs/protocol/llm-ipc-v1.md`), does the `hello`/`hello_ack` handshake,
//!   and routes streamed `llm_token`/`llm_done`/`error` back to the caller. A
//!   future BYO-HTTP or llama.cpp backend implements the same trait without
//!   touching the orchestration above it.
//! - [`LlmManager`] — reads `transcript.json` + `scratchpad.md`, assembles the
//!   prompt, streams tokens to the UI as `llm:*` events, and writes
//!   `<Title>.md` (YAML frontmatter from `session.json`) into the vault. This
//!   policy lives in the core (text crosses IPC freely, unlike engine audio),
//!   so it is shared across every backend.
//!
//! Lock discipline mirrors `sidecar.rs`: the std mutex guarding [`LlmLink`] is
//! never held across an await; spawn is serialized by an async gate.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use tauri::{AppHandle, Emitter};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::{mpsc, oneshot};

use crate::events;
use crate::llm_protocol::{
    EnhanceOptions, FinishReason, LlmCoreMessage, LlmErrorCode, LlmMessage, ModelStage, Stats,
};
use crate::protocol::Segment;

pub const LLM_SIDECAR_NAME: &str = "minutiae-llm";
/// First model. Reasoning model → `enable_thinking=false` (`/no_think`) for
/// summarization (see `docs/milestones.md` M2 step 3).
pub const DEFAULT_LLM_MODEL: &str = "mlx-community/Qwen3.5-4B-MLX-4bit";

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
/// Generous: a first enhance may download ~2.85 GB of weights before the first
/// token. The stream itself keeps the UI alive with `model_progress`.
const ENHANCE_MAX_TOKENS: u32 = 1536;
/// Thinking mode needs headroom for the `<think>` reasoning *plus* the answer.
const THINKING_MAX_TOKENS: u32 = 3584;

#[derive(Debug, thiserror::Error)]
pub enum LlmError {
    #[error("the language model is not running")]
    NotRunning,
    #[error("could not start the language model: {0}")]
    Spawn(String),
    #[error("the language model did not respond in time")]
    Timeout,
    #[error("an enhancement is already running")]
    Busy,
    #[error("enhancement cancelled")]
    Cancelled,
    #[error("language model error ({code:?}): {message}")]
    Sidecar { code: LlmErrorCode, message: String },
    #[error("the language model stopped unexpectedly")]
    Disconnected,
    #[error("no finished session to enhance yet")]
    NoSession,
    #[error("choose a vault folder first")]
    NoVault,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("could not read the session: {0}")]
    Json(#[from] serde_json::Error),
    #[error("{0}")]
    Other(String),
}

// ---------------------------------------------------------------------------
// Backend seam

/// What the core hands the transport for one completion.
#[derive(Debug, Clone)]
pub struct EnhanceRequest {
    pub model: String,
    pub system: Option<String>,
    pub prompt: String,
    pub options: EnhanceOptions,
}

/// One unit of a streamed completion, surfaced to the orchestration layer.
#[derive(Debug)]
pub enum EnhanceEvent {
    Progress { pct: f64, stage: ModelStage },
    Token(String),
    Done { finish_reason: FinishReason, stats: Stats },
    Failed { code: LlmErrorCode, message: String },
}

/// Drain `events` until `Done`/`Failed` (or the channel closes on disconnect).
pub struct EnhanceHandle {
    pub request_id: String,
    pub events: mpsc::UnboundedReceiver<EnhanceEvent>,
}

/// The transport seam. One impl today ([`LocalSidecar`]); BYO-HTTP and
/// llama.cpp slot in here without changing [`LlmManager`].
#[allow(async_fn_in_trait)]
pub trait LlmBackend: Send + Sync {
    /// Spawn + handshake if not already live. Idempotent.
    async fn ensure_ready(&self) -> Result<(), LlmError>;
    /// Begin one streamed completion. Errors immediately if one is in flight.
    async fn enhance(&self, req: EnhanceRequest) -> Result<EnhanceHandle, LlmError>;
    /// Cancel the active generation, if any (best effort).
    async fn cancel(&self) -> Result<(), LlmError>;
}

// ---------------------------------------------------------------------------
// LocalSidecar

/// State tied to the current `minutiae-llm` process.
#[derive(Default)]
struct LlmLink {
    child: Option<CommandChild>,
    ready: bool,
    /// Correlated single responses: hello → hello_ack, ping → pong.
    pending: HashMap<String, oneshot::Sender<LlmMessage>>,
    /// The single in-flight generation (the protocol allows one at a time).
    active: Option<ActiveStream>,
}

struct ActiveStream {
    request_id: String,
    sink: mpsc::UnboundedSender<EnhanceEvent>,
}

struct LlmShared {
    app: AppHandle,
    link: Mutex<LlmLink>,
}

/// MLX/Qwen3.5 sidecar over NDJSON stdio. Lazily spawned on first enhance.
pub struct LocalSidecar {
    shared: Arc<LlmShared>,
    /// Serializes spawn attempts so two concurrent enhances don't both spawn.
    spawn_gate: tokio::sync::Mutex<()>,
}

impl LocalSidecar {
    pub fn new(app: AppHandle) -> Self {
        Self {
            shared: Arc::new(LlmShared {
                app,
                link: Mutex::new(LlmLink::default()),
            }),
            spawn_gate: tokio::sync::Mutex::new(()),
        }
    }

    fn is_ready(&self) -> bool {
        self.shared.link.lock().unwrap().ready
    }

    fn send(&self, msg: &LlmCoreMessage) -> Result<(), LlmError> {
        let mut link = self.shared.link.lock().unwrap();
        let child = link.child.as_mut().ok_or(LlmError::NotRunning)?;
        let mut line = serde_json::to_vec(msg)?;
        line.push(b'\n');
        child
            .write(&line)
            .map_err(|e| LlmError::Other(format!("write to language model failed: {e}")))
    }

    /// Download (if needed) and load the model, invoking `on_progress` for each
    /// `model_progress` and resolving when `model_ready` arrives. Uses the active
    /// stream for progress and a correlated waiter for the ready reply. No
    /// timeout — a first download can take minutes; a dead process surfaces as
    /// `Disconnected` when the waiter's sender drops.
    async fn prepare<F>(&self, on_progress: F) -> Result<(), LlmError>
    where
        F: Fn(f64, ModelStage),
    {
        self.ensure_ready().await?;

        let id = new_id();
        let (sink, mut progress_rx) = mpsc::unbounded_channel();
        let (tx, mut ack_rx) = oneshot::channel();
        {
            let mut link = self.shared.link.lock().unwrap();
            if link.active.is_some() {
                return Err(LlmError::Busy);
            }
            link.active = Some(ActiveStream {
                request_id: id.clone(),
                sink,
            });
            link.pending.insert(id.clone(), tx);
        }

        if let Err(e) = self.send(&LlmCoreMessage::prepare_model(id.clone(), DEFAULT_LLM_MODEL)) {
            let mut link = self.shared.link.lock().unwrap();
            link.active = None;
            link.pending.remove(&id);
            return Err(e);
        }

        let result = loop {
            tokio::select! {
                ack = &mut ack_rx => break match ack {
                    Ok(LlmMessage::ModelReady { .. }) => Ok(()),
                    Ok(_) => Err(LlmError::Other("unexpected prepare reply".into())),
                    Err(_) => Err(LlmError::Disconnected),
                },
                Some(ev) = progress_rx.recv() => {
                    if let EnhanceEvent::Progress { pct, stage } = ev {
                        on_progress(pct, stage);
                    }
                }
            }
        };

        let mut link = self.shared.link.lock().unwrap();
        if link.active.as_ref().map(|a| a.request_id.as_str()) == Some(id.as_str()) {
            link.active = None;
        }
        link.pending.remove(&id);
        result
    }
}

impl LlmBackend for LocalSidecar {
    async fn ensure_ready(&self) -> Result<(), LlmError> {
        if self.is_ready() {
            return Ok(());
        }
        // Serialize: a racing caller may have spawned while we awaited the gate.
        let _gate = self.spawn_gate.lock().await;
        if self.is_ready() {
            return Ok(());
        }

        let command = self
            .shared
            .app
            .shell()
            .sidecar(LLM_SIDECAR_NAME)
            .map_err(|e| LlmError::Spawn(e.to_string()))?;
        let (rx, child) = command.spawn().map_err(|e| LlmError::Spawn(e.to_string()))?;
        let pid = child.pid();
        tracing::info!(pid, "llm sidecar spawned");

        {
            let mut link = self.shared.link.lock().unwrap();
            link.child = Some(child);
            link.ready = false;
            link.pending.clear();
            link.active = None;
        }
        tauri::async_runtime::spawn(reader(self.shared.clone(), rx));

        // hello/hello_ack handshake.
        let id = new_id();
        let (tx, ack_rx) = oneshot::channel();
        self.shared
            .link
            .lock()
            .unwrap()
            .pending
            .insert(id.clone(), tx);
        self.send(&LlmCoreMessage::hello(id.clone()))?;

        match tokio::time::timeout(HANDSHAKE_TIMEOUT, ack_rx).await {
            Ok(Ok(LlmMessage::HelloAck {
                protocol_version,
                runtime,
                loaded_model,
                ..
            })) => {
                tracing::info!(
                    protocol_version,
                    runtime,
                    loaded_model = loaded_model.as_deref().unwrap_or("none"),
                    "llm handshake complete"
                );
                self.shared.link.lock().unwrap().ready = true;
                Ok(())
            }
            Ok(Ok(_)) => Err(LlmError::Other("unexpected handshake reply".into())),
            // sender dropped — reader saw the process die
            Ok(Err(_)) => Err(LlmError::Disconnected),
            Err(_) => {
                self.shared.link.lock().unwrap().pending.remove(&id);
                kill(&self.shared);
                Err(LlmError::Timeout)
            }
        }
    }

    async fn enhance(&self, req: EnhanceRequest) -> Result<EnhanceHandle, LlmError> {
        self.ensure_ready().await?;

        let id = new_id();
        let (sink, events) = mpsc::unbounded_channel();
        {
            let mut link = self.shared.link.lock().unwrap();
            if link.active.is_some() {
                return Err(LlmError::Busy);
            }
            link.active = Some(ActiveStream {
                request_id: id.clone(),
                sink,
            });
        }

        let msg = LlmCoreMessage::enhance(
            id.clone(),
            req.model,
            req.prompt,
            req.system,
            req.options,
        );
        if let Err(e) = self.send(&msg) {
            self.shared.link.lock().unwrap().active = None;
            return Err(e);
        }
        Ok(EnhanceHandle {
            request_id: id,
            events,
        })
    }

    async fn cancel(&self) -> Result<(), LlmError> {
        let active_id = {
            let link = self.shared.link.lock().unwrap();
            link.active.as_ref().map(|a| a.request_id.clone())
        };
        match active_id {
            Some(request_id) => self.send(&LlmCoreMessage::cancel(new_id(), request_id)),
            None => Ok(()),
        }
    }
}

/// Reader task: parse the sidecar's stdout NDJSON and route each message.
async fn reader(shared: Arc<LlmShared>, mut rx: tauri::async_runtime::Receiver<CommandEvent>) {
    while let Some(event) = rx.recv().await {
        match event {
            CommandEvent::Stdout(bytes) => {
                for line in bytes.split(|b| *b == b'\n') {
                    if line.iter().all(u8::is_ascii_whitespace) {
                        continue;
                    }
                    match serde_json::from_slice::<LlmMessage>(line) {
                        Ok(msg) => route(&shared, msg),
                        Err(e) => tracing::warn!(
                            "undecodable llm line ({e}): {}",
                            String::from_utf8_lossy(line)
                        ),
                    }
                }
            }
            CommandEvent::Stderr(bytes) => {
                let text = String::from_utf8_lossy(&bytes);
                let text = text.trim_end();
                if !text.is_empty() {
                    tracing::warn!(target: "minutiae::llm", "{text}");
                }
            }
            CommandEvent::Error(e) => tracing::warn!("llm io error: {e}"),
            CommandEvent::Terminated(payload) => {
                tracing::warn!(
                    "llm sidecar terminated (code {:?}, signal {:?})",
                    payload.code,
                    payload.signal
                );
                on_down(&shared);
                return;
            }
            _ => {}
        }
    }
    on_down(&shared);
}

/// Route one decoded message: stream events to the active enhance, resolve
/// correlated waiters, forward model-load progress.
fn route(shared: &Arc<LlmShared>, msg: LlmMessage) {
    match msg {
        LlmMessage::HelloAck { .. } | LlmMessage::ModelReady { .. } | LlmMessage::Pong { .. } => {
            let id = msg
                .id()
                .expect("correlated reply carries an id")
                .to_string();
            let waiter = shared.link.lock().unwrap().pending.remove(&id);
            if let Some(tx) = waiter {
                let _ = tx.send(msg);
            } else {
                tracing::warn!(id, "unsolicited llm reply");
            }
        }
        LlmMessage::ModelProgress { pct, stage, .. } => {
            to_active(shared, EnhanceEvent::Progress { pct, stage });
        }
        LlmMessage::LlmToken { id, text, .. } => {
            with_active(shared, &id, EnhanceEvent::Token(text));
        }
        LlmMessage::LlmDone {
            id,
            finish_reason,
            stats,
            ..
        } => {
            with_active(
                shared,
                &id,
                EnhanceEvent::Done {
                    finish_reason,
                    stats,
                },
            );
            clear_active(shared, &id);
        }
        LlmMessage::Error {
            code,
            message,
            fatal,
            request_id,
            ..
        } => {
            tracing::warn!(?code, fatal, "llm error: {message}");
            // Tie it to the active generation if the ids line up (or if the
            // error is id-less — only one generation runs at a time).
            let active_id = shared
                .link
                .lock()
                .unwrap()
                .active
                .as_ref()
                .map(|a| a.request_id.clone());
            let belongs = match (&request_id, &active_id) {
                (Some(r), Some(a)) => r == a,
                (None, Some(_)) => true,
                _ => false,
            };
            if let Some(active_id) = active_id.filter(|_| belongs) {
                with_active(
                    shared,
                    &active_id,
                    EnhanceEvent::Failed { code, message },
                );
                clear_active(shared, &active_id);
            } else {
                // No active generation: a handshake/prepare failure. Fail any
                // pending waiter so callers don't hang to the timeout.
                let waiter = request_id.and_then(|r| shared.link.lock().unwrap().pending.remove(&r));
                drop(waiter);
            }
            // fatal: the process exits; Terminated handling marks us down.
        }
        LlmMessage::Unknown => tracing::debug!("ignoring unknown llm message"),
    }
}

/// Send to the active stream only if its id matches.
fn with_active(shared: &Arc<LlmShared>, id: &str, event: EnhanceEvent) {
    let link = shared.link.lock().unwrap();
    if let Some(active) = link.active.as_ref() {
        if active.request_id == id {
            let _ = active.sink.send(event);
        }
    }
}

/// Send to whatever stream is active (for id-less progress).
fn to_active(shared: &Arc<LlmShared>, event: EnhanceEvent) {
    let link = shared.link.lock().unwrap();
    if let Some(active) = link.active.as_ref() {
        let _ = active.sink.send(event);
    }
}

fn clear_active(shared: &Arc<LlmShared>, id: &str) {
    let mut link = shared.link.lock().unwrap();
    if link.active.as_ref().map(|a| a.request_id.as_str()) == Some(id) {
        link.active = None;
    }
}

/// The sidecar died: drop the child, fail in-flight waiters (closing the
/// stream channel surfaces `Disconnected` to the orchestration loop).
fn on_down(shared: &Arc<LlmShared>) {
    let mut link = shared.link.lock().unwrap();
    if let Some(child) = link.child.take() {
        let _ = child.kill();
    }
    link.ready = false;
    link.pending.clear(); // dropping senders fails awaiting handshakes
    link.active = None; // dropping the sink closes the stream
}

fn kill(shared: &Arc<LlmShared>) {
    let child = shared.link.lock().unwrap().child.take();
    if let Some(child) = child {
        let _ = child.kill();
    }
    shared.link.lock().unwrap().ready = false;
}

fn new_id() -> String {
    ulid::Ulid::new().to_string()
}

/// Whether the model weights are already on disk (so enhancing won't trigger a
/// multi-GB download). Inspects the HuggingFace hub cache the sidecar downloads
/// into (`$HF_HOME` or `~/.cache/huggingface`), without spawning the sidecar.
pub fn model_downloaded() -> bool {
    let root = std::env::var_os("HF_HOME").map(PathBuf::from).or_else(|| {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache").join("huggingface"))
    });
    let Some(root) = root else {
        return false;
    };
    let folder = format!("models--{}", DEFAULT_LLM_MODEL.replace('/', "--"));
    let snapshots = root.join("hub").join(folder).join("snapshots");
    let Ok(entries) = std::fs::read_dir(&snapshots) else {
        return false;
    };
    // A completed snapshot has the resolved weights (single file or a shard index).
    entries.flatten().any(|e| {
        let dir = e.path();
        dir.join("model.safetensors").exists()
            || dir.join("model.safetensors.index.json").exists()
    })
}

// ---------------------------------------------------------------------------
// LlmManager — orchestration (read session → prompt → stream → write vault)

/// Tauri-managed; owns the backend(s) and the enhancement policy.
///
/// The transport is chosen per-enhance: the local MLX sidecar by default, or
/// the cloud backend (SaaS tier) when the user has selected cloud enrichment
/// and is signed in. `enhance`/`cancel` route through [`Self::enhance_backend`]
/// / [`Self::cancel_backend`]; model download (`prepare`) is local-only.
pub struct LlmManager {
    app: AppHandle,
    local: LocalSidecar,
    /// Cloud enrichment transport (SaaS tier). Holds an HTTPS client + token
    /// source; never spawns a process.
    #[cfg(feature = "saas")]
    cloud: crate::saas::CloudBackend,
    /// True once the model is loaded into the sidecar this session (after a
    /// prepare or a successful enhance). Resets when the process dies.
    resident: std::sync::atomic::AtomicBool,
}

/// What the `enhance_session` command gets back.
#[derive(Debug, Clone)]
pub struct EnhancedDoc {
    pub path: PathBuf,
}

impl LlmManager {
    pub fn new(app: AppHandle) -> Self {
        Self {
            local: LocalSidecar::new(app.clone()),
            #[cfg(feature = "saas")]
            cloud: crate::saas::CloudBackend::new(app.clone()),
            app,
            resident: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Whether cloud enrichment is the active transport for the next enhance.
    /// OSS builds (no `saas` feature) always answer false → local sidecar.
    #[cfg(feature = "saas")]
    fn cloud_selected(&self) -> bool {
        self.cloud.is_active()
    }

    /// Begin a completion on the active transport (cloud if selected & ready,
    /// else the local sidecar).
    async fn enhance_backend(&self, req: EnhanceRequest) -> Result<EnhanceHandle, LlmError> {
        #[cfg(feature = "saas")]
        if self.cloud_selected() {
            return self.cloud.enhance(req).await;
        }
        self.local.enhance(req).await
    }

    /// Cancel the active transport's in-flight generation.
    async fn cancel_backend(&self) -> Result<(), LlmError> {
        #[cfg(feature = "saas")]
        if self.cloud_selected() {
            return self.cloud.cancel().await;
        }
        self.local.cancel().await
    }

    /// Whether the model weights are on disk, and whether they're resident in
    /// the sidecar this session. The UI gates "Enhance" on `downloaded`.
    pub fn status(&self) -> events::LlmStatusPayload {
        #[cfg(feature = "saas")]
        let cloud_active = self.cloud_selected();
        #[cfg(not(feature = "saas"))]
        let cloud_active = false;
        events::LlmStatusPayload {
            downloaded: model_downloaded(),
            ready: self.resident.load(std::sync::atomic::Ordering::SeqCst),
            cloud_active,
        }
    }

    /// Download (if needed) and load the model on demand, streaming
    /// `llm:model_progress` and finishing with `llm:model_ready`. Triggered
    /// explicitly by the user — the model is never prepared at launch.
    pub async fn prepare_model(&self) -> Result<(), LlmError> {
        let app = self.app.clone();
        let res = self
            .local
            .prepare(move |pct, stage| {
                let _ = app.emit(
                    events::LLM_MODEL_PROGRESS,
                    events::LlmProgressPayload {
                        pct,
                        stage: stage_str(stage).into(),
                    },
                );
            })
            .await;
        if res.is_ok() {
            self.resident
                .store(true, std::sync::atomic::Ordering::SeqCst);
            let _ = self
                .app
                .emit(events::LLM_MODEL_READY, events::LlmModelReadyPayload { ready: true });
        }
        res
    }

    /// Enhance the focused session: read its transcript + notes, stream the
    /// model's Markdown to the UI, and write `<Title>.md` into `vault_dir`.
    pub async fn enhance(
        &self,
        session_dir: PathBuf,
        vault_dir: PathBuf,
        thinking: bool,
    ) -> Result<EnhancedDoc, LlmError> {
        let session = SessionMeta::read(&session_dir)?;
        let transcript = read_transcript(&session_dir)?;
        if transcript.trim().is_empty() {
            return Err(LlmError::Other(
                "this session has no transcript to enhance yet".into(),
            ));
        }
        let scratchpad = std::fs::read_to_string(session_dir.join("scratchpad.md"))
            .unwrap_or_default();

        // Title: keep an existing one (e.g. a calendar title later); otherwise
        // ask the model for a concise title and persist it so Recents + the note
        // use it instead of the date stamp. Best-effort — falls back to the date.
        let existing = session
            .title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_string);
        let title = match existing {
            Some(t) => t,
            None => match self.generate_title(&transcript, &scratchpad).await {
                Some(t) => {
                    if let Err(e) = persist_title(&session_dir, &t) {
                        tracing::warn!("could not persist generated title: {e}");
                    }
                    t
                }
                None => session.title(),
            },
        };

        let prompt = build_prompt(&transcript, &scratchpad);
        // Sampling (temperature/top_p/…) is the model card's per-mode preset,
        // applied in the sidecar; we leave temperature unset to use it.
        let req = EnhanceRequest {
            model: DEFAULT_LLM_MODEL.to_string(),
            system: Some(system_prompt(thinking)),
            prompt,
            options: EnhanceOptions {
                max_tokens: Some(if thinking {
                    THINKING_MAX_TOKENS
                } else {
                    ENHANCE_MAX_TOKENS
                }),
                temperature: None,
                enable_thinking: Some(thinking),
            },
        };

        let handle = self.enhance_backend(req).await?;
        tracing::info!(request_id = %handle.request_id, "enhancement streaming");
        let mut events = handle.events;
        let mut body = String::new();
        let stats = loop {
            match events.recv().await {
                Some(EnhanceEvent::Progress { pct, stage }) => {
                    let _ = self.app.emit(
                        events::LLM_PROGRESS,
                        events::LlmProgressPayload {
                            pct,
                            stage: stage_str(stage).into(),
                        },
                    );
                }
                Some(EnhanceEvent::Token(text)) => {
                    body.push_str(&text);
                    let _ = self
                        .app
                        .emit(events::LLM_TOKEN, events::LlmTokenPayload { text });
                }
                Some(EnhanceEvent::Done {
                    finish_reason,
                    stats,
                }) => match finish_reason {
                    // Discard a cancelled run — never leave a partial note.
                    FinishReason::Cancelled => {
                        tracing::info!("enhancement cancelled; no note written");
                        return Err(LlmError::Cancelled);
                    }
                    FinishReason::Length => {
                        tracing::warn!("enhancement hit the token cap; the note may be truncated");
                        break stats;
                    }
                    _ => break stats,
                },
                Some(EnhanceEvent::Failed { code, message }) => {
                    return Err(LlmError::Sidecar { code, message });
                }
                None => return Err(LlmError::Disconnected),
            }
        };
        let tokens_per_s = stats.tokens_per_s;

        let markdown = render_note(&session, &title, strip_think(&body), DEFAULT_LLM_MODEL);
        let path = write_note(&vault_dir, &title, &markdown)?;
        // Refresh the raw-transcript note too, so the vault holds both the
        // enhanced note and a readable transcript under the same (now better)
        // title. Best-effort — a transcript-export hiccup must not fail enhance.
        if let Err(e) = write_transcript_note(&vault_dir, &session_dir) {
            tracing::warn!("could not write transcript note: {e}");
        }
        let file = path
            .file_name()
            .map(|f| f.to_string_lossy().into_owned())
            .unwrap_or_default();
        tracing::info!(path = %path.display(), "enhanced note written");
        self.resident
            .store(true, std::sync::atomic::Ordering::SeqCst);
        let _ = self.app.emit(
            events::LLM_DONE,
            events::LlmDonePayload {
                path: path.to_string_lossy().into_owned(),
                file,
                tokens_per_s,
            },
        );
        Ok(EnhancedDoc { path })
    }

    /// Best-effort concise meeting title from the transcript/notes. Runs as a
    /// short, separate generation (the model is resident from the notes call, or
    /// loads here first — forwarding load progress to the UI). Returns None on
    /// any failure so the caller falls back to the date-stamp title.
    async fn generate_title(&self, transcript: &str, scratchpad: &str) -> Option<String> {
        let req = EnhanceRequest {
            model: DEFAULT_LLM_MODEL.to_string(),
            system: Some(TITLE_SYSTEM_PROMPT.to_string()),
            prompt: build_title_prompt(transcript, scratchpad),
            options: EnhanceOptions {
                max_tokens: Some(24),
                temperature: None,
                enable_thinking: Some(false),
            },
        };
        let handle = self.enhance_backend(req).await.ok()?;
        let mut events = handle.events;
        let mut body = String::new();
        loop {
            match events.recv().await? {
                EnhanceEvent::Progress { pct, stage } => {
                    // Keep the model-load bar alive during this first call.
                    let _ = self.app.emit(
                        events::LLM_PROGRESS,
                        events::LlmProgressPayload {
                            pct,
                            stage: stage_str(stage).into(),
                        },
                    );
                }
                EnhanceEvent::Token(text) => body.push_str(&text),
                EnhanceEvent::Done { finish_reason, .. } => {
                    if matches!(finish_reason, FinishReason::Cancelled) {
                        return None;
                    }
                    break;
                }
                EnhanceEvent::Failed { .. } => return None,
            }
        }
        clean_title(&body)
    }

    pub async fn cancel(&self) -> Result<(), LlmError> {
        self.cancel_backend().await
    }

    /// Surface a failure to the enhancement UI (the command also returns it).
    pub fn emit_error(&self, message: &str) {
        let _ = self.app.emit(
            events::LLM_ERROR,
            events::LlmErrorPayload {
                message: message.to_string(),
            },
        );
    }
}

fn stage_str(stage: ModelStage) -> &'static str {
    match stage {
        ModelStage::Downloading => "downloading",
        ModelStage::Loading => "loading",
        ModelStage::Unknown => "loading",
    }
}

// ---------------------------------------------------------------------------
// Prompt assembly + note rendering (pure helpers, unit-tested)

const SYSTEM_PROMPT: &str = "You are an expert assistant that turns a raw two-channel meeting \
transcript and the user's rough notes into clean, well-structured meeting notes in Markdown. \
\"Me\" is the user; \"Them\" is everyone else. Be faithful to what was said — do not invent \
facts, names, numbers, or decisions. Output only the body of the notes in Markdown using \
section headings and bullet lists (a Summary, Key points, Decisions, and Action items with \
owners where stated). Do not include a top-level title heading; it is added separately.";

/// Instruct mode (default): go straight to the finished notes, no reasoning.
const INSTRUCT_ADDENDUM: &str = "Respond directly: write the finished notes immediately, with \
no preamble, no reasoning, and no meta-commentary.";

/// System prompt for the short title generation.
const TITLE_SYSTEM_PROMPT: &str = "You write a short, specific title for a meeting from its \
transcript and notes. Reply with the title only — 3 to 8 words, in Title Case, no surrounding \
quotes, no trailing punctuation, no preamble.";

/// Compose the system prompt for the requested mode. Thinking mode relies on the
/// model's built-in reasoning (the `enable_thinking` chat-template kwarg) rather
/// than a "think first" instruction — telling Qwen3.5 to think *and* enabling
/// thinking makes it meta-ramble and never emit the notes. Instruct mode adds an
/// explicit "be direct" nudge on top of `enable_thinking=false`.
fn system_prompt(thinking: bool) -> String {
    if thinking {
        SYSTEM_PROMPT.to_string()
    } else {
        format!("{SYSTEM_PROMPT} {INSTRUCT_ADDENDUM}")
    }
}

fn build_prompt(transcript: &str, scratchpad: &str) -> String {
    let notes = scratchpad.trim();
    let notes_block = if notes.is_empty() {
        "(none)".to_string()
    } else {
        notes.to_string()
    };
    format!(
        "Transcript:\n\n{transcript}\n\n---\n\nThe user's rough notes during the meeting:\n\n\
{notes_block}\n\n---\n\nWrite the meeting notes now."
    )
}

fn build_title_prompt(transcript: &str, scratchpad: &str) -> String {
    let notes = scratchpad.trim();
    let notes_block = if notes.is_empty() { "(none)" } else { notes };
    format!(
        "Transcript:\n\n{transcript}\n\n---\n\nThe user's rough notes:\n\n{notes_block}\n\n---\n\n\
Give a short, specific title for this meeting."
    )
}

/// Clean a raw model title into a single tidy line, or None if empty.
fn clean_title(raw: &str) -> Option<String> {
    let stripped = strip_think(raw);
    let line = stripped.lines().map(str::trim).find(|l| !l.is_empty())?;
    let line = line
        .trim_start_matches('#')
        .trim()
        .trim_start_matches("Title:")
        .trim_start_matches("title:");
    // Drop wrapping whitespace, quotes, asterisks, and stray punctuation the
    // model sometimes adds — in any order — while keeping internal punctuation.
    let line = line.trim_matches(|c: char| {
        c.is_whitespace() || matches!(c, '"' | '\'' | '*' | '.' | ':' | ';' | ',')
    });
    if line.is_empty() {
        return None;
    }
    // Keep titles to a sane length (whole words).
    const MAX: usize = 80;
    let title = if line.chars().count() > MAX {
        let mut t: String = line.chars().take(MAX).collect();
        if let Some(sp) = t.rfind(' ') {
            t.truncate(sp);
        }
        t
    } else {
        line.to_string()
    };
    Some(title)
}

/// Patch the `title` field into a session's `session.json` (preserving the rest)
/// so Recents and re-enhancement read it back.
fn persist_title(session_dir: &Path, title: &str) -> Result<(), LlmError> {
    let path = session_dir.join("session.json");
    let mut value: serde_json::Value = serde_json::from_slice(&std::fs::read(&path)?)?;
    if let Some(obj) = value.as_object_mut() {
        obj.insert("title".into(), serde_json::Value::String(title.to_string()));
    }
    let bytes = serde_json::to_vec_pretty(&value)?;
    crate::settings::write_atomic(&path, &bytes)
        .map_err(|e| LlmError::Other(format!("could not write session.json: {e}")))
}

/// Remove the model's reasoning so only the answer reaches the vault.
///
/// Two shapes to handle:
/// 1. Qwen3.5 thinking mode streams `reasoning… </think> answer` — the opening
///    `<think>` lives in the prompt, so the output has only the *closing* tag.
///    Drop everything up to and including the first `</think>` that has no
///    `<think>` before it.
/// 2. A stray complete `<think>…</think>` pair (e.g. a leak in instruct mode):
///    excise the pair, preserving text outside it.
fn strip_think(body: &str) -> String {
    let mut out = body.to_string();

    // (1) close-only stream: a </think> with no <think> ahead of it.
    if let Some(close) = out.find("</think>") {
        if !out[..close].contains("<think>") {
            out = out[close + "</think>".len()..].to_string();
        }
    }

    // (2) any remaining paired blocks.
    while let Some(start) = out.find("<think>") {
        match out[start..].find("</think>") {
            Some(rel_end) => {
                let end = start + rel_end + "</think>".len();
                out.replace_range(start..end, "");
            }
            // unterminated — drop everything from the tag on
            None => {
                out.truncate(start);
                break;
            }
        }
    }
    out.trim().to_string()
}

fn render_note(session: &SessionMeta, title: &str, body: String, model: &str) -> String {
    let mut fm = String::new();
    fm.push_str("---\n");
    fm.push_str(&format!("title: {}\n", yaml_scalar(title)));
    if let Some(date) = &session.started_at {
        fm.push_str(&format!("date: {}\n", yaml_scalar(date)));
    }
    if let Some(d) = session.duration_s {
        fm.push_str(&format!("duration_min: {}\n", (d / 60.0).round() as i64));
    }
    if let Some(id) = &session.session_id {
        fm.push_str(&format!("session_id: {}\n", yaml_scalar(id)));
    }
    fm.push_str("generated_by: minutiae\n");
    fm.push_str(&format!("model: {}\n", yaml_scalar(model)));
    fm.push_str("---\n\n");
    fm.push_str(&format!("# {}\n\n", title));
    fm.push_str(body.trim());
    fm.push('\n');
    fm
}

/// Minimal YAML scalar quoting: always double-quote and escape `"`/`\`, which
/// is valid for any string value.
fn yaml_scalar(s: &str) -> String {
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Write `<slug>.md` into the vault, appending `-N` on collision so a re-run
/// never clobbers an earlier note.
fn write_note(vault_dir: &Path, title: &str, markdown: &str) -> Result<PathBuf, LlmError> {
    if !vault_dir.is_dir() {
        return Err(LlmError::NoVault);
    }
    let slug = slugify(title);
    let mut candidate = vault_dir.join(format!("{slug}.md"));
    let mut n = 2;
    while candidate.exists() {
        candidate = vault_dir.join(format!("{slug}-{n}.md"));
        n += 1;
    }
    // Atomic-ish: temp + rename within the vault.
    crate::settings::write_atomic(&candidate, markdown.as_bytes())?;
    Ok(candidate)
}

/// Write the raw transcript as a readable Markdown note in the vault, alongside
/// any enhanced note. Carries `type: transcript` frontmatter so it is never
/// confused with the enhanced note. Idempotent per session: overwrites the
/// session's existing transcript note instead of proliferating `-N` copies, so
/// re-running on stop and again on enhance keeps a single file. Returns the
/// written path, or `None` when there's nothing transcribed yet.
pub fn write_transcript_note(
    vault_dir: &Path,
    session_dir: &Path,
) -> Result<Option<PathBuf>, LlmError> {
    if !vault_dir.is_dir() {
        return Err(LlmError::NoVault);
    }
    let session = SessionMeta::read(session_dir)?;
    let body = render_transcript_markdown(&read_transcript_segments(session_dir));
    if body.trim().is_empty() {
        return Ok(None); // nothing was transcribed — don't litter the vault
    }
    let title = session.title();
    let markdown = render_transcript_note(&session, &title, &body);

    // Overwrite this session's existing transcript note if there is one (e.g.
    // written on stop, now refreshed on enhance with a better title); else pick
    // a fresh, collision-free slug.
    let path = session
        .session_id
        .as_deref()
        .and_then(|id| find_transcript_note(vault_dir, id))
        .unwrap_or_else(|| {
            let slug = slugify(&format!("{title} transcript"));
            let mut candidate = vault_dir.join(format!("{slug}.md"));
            let mut n = 2;
            while candidate.exists() {
                candidate = vault_dir.join(format!("{slug}-{n}.md"));
                n += 1;
            }
            candidate
        });
    crate::settings::write_atomic(&path, markdown.as_bytes())?;
    Ok(Some(path))
}

/// Render the transcript as speaker-labelled Markdown: a bold speaker + a
/// timestamp heading per turn, with consecutive same-speaker segments merged
/// into one paragraph. Empty when nothing was transcribed.
fn render_transcript_markdown(segments: &[Segment]) -> String {
    let mut out = String::new();
    // (speaker, turn start time, accumulated text)
    let mut turn: Option<(&str, f64, String)> = None;
    for seg in segments {
        let text = seg.text.trim();
        if text.is_empty() {
            continue;
        }
        let speaker = speaker_label(&seg.channel);
        match turn.as_mut() {
            Some((sp, _, body)) if *sp == speaker => {
                body.push(' ');
                body.push_str(text);
            }
            _ => {
                if let Some((sp, t0, body)) = turn.take() {
                    push_turn(&mut out, sp, t0, &body);
                }
                turn = Some((speaker, seg.t0, text.to_string()));
            }
        }
    }
    if let Some((sp, t0, body)) = turn.take() {
        push_turn(&mut out, sp, t0, &body);
    }
    out
}

fn speaker_label(channel: &str) -> &'static str {
    match channel {
        "me" => "Me",
        c if c.starts_with("them") => "Them",
        _ => "Them",
    }
}

fn push_turn(out: &mut String, speaker: &str, t0: f64, body: &str) {
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(&format!("**{speaker}** · {}\n\n{}\n", fmt_clock(t0), body));
}

/// Session-relative seconds → `m:ss` (or `h:mm:ss` past an hour).
fn fmt_clock(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

fn render_transcript_note(session: &SessionMeta, title: &str, body: &str) -> String {
    let mut fm = String::new();
    fm.push_str("---\n");
    fm.push_str(&format!("title: {}\n", yaml_scalar(&format!("{title} — Transcript"))));
    if let Some(date) = &session.started_at {
        fm.push_str(&format!("date: {}\n", yaml_scalar(date)));
    }
    if let Some(d) = session.duration_s {
        fm.push_str(&format!("duration_min: {}\n", (d / 60.0).round() as i64));
    }
    if let Some(id) = &session.session_id {
        fm.push_str(&format!("session_id: {}\n", yaml_scalar(id)));
    }
    fm.push_str("type: transcript\n");
    fm.push_str("generated_by: minutiae\n");
    fm.push_str("---\n\n");
    fm.push_str(&format!("# {title} — Transcript\n\n"));
    fm.push_str(body.trim());
    fm.push('\n');
    fm
}

/// Path of this session's transcript note in the vault, if one has been written.
/// Lets callers that only have the session folder (e.g. "reveal in Finder") find
/// the `.md` without knowing how its filename was slugified.
pub fn transcript_note_path(vault_dir: &Path, session_dir: &Path) -> Option<PathBuf> {
    let session = SessionMeta::read(session_dir).ok()?;
    find_transcript_note(vault_dir, session.session_id.as_deref()?)
}

/// Locate this session's existing transcript note (`type: transcript` +
/// matching `session_id`) so a re-export overwrites it in place.
fn find_transcript_note(vault: &Path, session_id: &str) -> Option<PathBuf> {
    for entry in std::fs::read_dir(vault).ok()?.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        if note_is_transcript_for(&path, session_id) {
            return Some(path);
        }
    }
    None
}

fn note_is_transcript_for(path: &Path, session_id: &str) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    let Some(rest) = text.strip_prefix("---\n") else {
        return false;
    };
    let Some(end) = rest.find("\n---") else {
        return false;
    };
    let (mut sid_match, mut is_transcript) = (false, false);
    for line in rest[..end].lines() {
        if let Some(v) = line.strip_prefix("session_id:") {
            sid_match = v.trim().trim_matches('"') == session_id;
        } else if let Some(v) = line.strip_prefix("type:") {
            is_transcript = v.trim().trim_matches('"') == "transcript";
        }
    }
    sid_match && is_transcript
}

/// Read `transcript.json` segments ordered by index (empty if none/unreadable).
fn read_transcript_segments(dir: &Path) -> Vec<Segment> {
    let Ok(bytes) = std::fs::read(dir.join("transcript.json")) else {
        return Vec::new();
    };
    let Ok(file) = serde_json::from_slice::<TranscriptFile>(&bytes) else {
        return Vec::new();
    };
    let mut segments = file.segments;
    segments.sort_by_key(|s| s.idx);
    segments
}

fn slugify(title: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for ch in title.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    let trimmed = out.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "meeting-notes".into()
    } else {
        trimmed
    }
}

// ---------------------------------------------------------------------------
// Session inputs

/// The subset of `session.json` we need for frontmatter + a title. Shared with
/// the Recents history reader (`history.rs`).
#[derive(Debug, Deserialize, Default)]
pub(crate) struct SessionMeta {
    #[serde(default)]
    pub(crate) session_id: Option<String>,
    #[serde(default)]
    pub(crate) started_at: Option<String>,
    #[serde(default)]
    pub(crate) duration_s: Option<f64>,
    /// M3 (EventKit) fills this; null until then.
    #[serde(default)]
    pub(crate) title: Option<String>,
    /// True when `history::recover_session_dir` synthesized this file rather
    /// than a clean finalize writing it. Such a stub has no engine/devices/audio
    /// and often no `started_at`, so it loses to a real `session.json` for the
    /// same session wherever the two compete (Recents dedupe, sync folder
    /// resolution).
    #[serde(default)]
    pub(crate) recovered: bool,
}

impl SessionMeta {
    pub(crate) fn read(dir: &Path) -> Result<Self, LlmError> {
        let path = dir.join("session.json");
        if !path.exists() {
            return Err(LlmError::NoSession);
        }
        Ok(serde_json::from_slice(&std::fs::read(path)?)?)
    }

    /// A human title: the calendar/event title if present, else a date stamp.
    pub(crate) fn title(&self) -> String {
        if let Some(t) = self.title.as_ref().map(|t| t.trim()).filter(|t| !t.is_empty()) {
            return t.to_string();
        }
        match self.started_at.as_deref() {
            // "2026-06-13T14:30:22Z" → "Meeting 2026-06-13 14:30"
            Some(ts) => {
                let pretty = ts.replace('T', " ");
                let pretty = pretty.trim_end_matches('Z');
                let pretty = pretty.get(..16).unwrap_or(pretty);
                format!("Meeting {pretty}")
            }
            None => "Meeting".to_string(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct TranscriptFile {
    #[serde(default)]
    segments: Vec<Segment>,
}

/// Render `transcript.json` as `Me:`/`Them:` lines in order.
fn read_transcript(dir: &Path) -> Result<String, LlmError> {
    let path = dir.join("transcript.json");
    if !path.exists() {
        return Ok(String::new());
    }
    let file: TranscriptFile = serde_json::from_slice(&std::fs::read(path)?)?;
    let mut segments = file.segments;
    segments.sort_by_key(|s| s.idx);
    let mut out = String::new();
    for seg in &segments {
        let text = seg.text.trim();
        if text.is_empty() {
            continue;
        }
        let who = match seg.channel.as_str() {
            "me" => "Me",
            c if c.starts_with("them") => "Them",
            _ => "Them",
        };
        out.push_str(who);
        out.push_str(": ");
        out.push_str(text);
        out.push('\n');
    }
    Ok(out)
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_handles_punctuation_and_empty() {
        assert_eq!(slugify("Q3 Planning / Roadmap!"), "Q3-Planning-Roadmap");
        assert_eq!(slugify("Meeting 2026-06-13 14:30"), "Meeting-2026-06-13-14-30");
        assert_eq!(slugify("***"), "meeting-notes");
        assert_eq!(slugify("  hello  "), "hello");
    }

    #[test]
    fn strip_think_removes_block() {
        assert_eq!(strip_think("<think>reasoning</think>\n\nAnswer"), "Answer");
        assert_eq!(strip_think("Answer only"), "Answer only");
        assert_eq!(strip_think("<think>never closed and dropped"), "");
        // leading text preserved, block excised
        assert_eq!(strip_think("A<think>x</think>B"), "AB");
        // Qwen3.5 thinking stream: reasoning then a bare close tag, no open tag.
        assert_eq!(
            strip_think("reasoning about it\n</think>\n\n# Notes\n\nBody"),
            "# Notes\n\nBody"
        );
    }

    #[test]
    fn yaml_scalar_quotes_and_escapes() {
        assert_eq!(yaml_scalar("plain"), "\"plain\"");
        assert_eq!(yaml_scalar("with \"quote\""), "\"with \\\"quote\\\"\"");
        assert_eq!(yaml_scalar("a: b # c"), "\"a: b # c\"");
    }

    #[test]
    fn title_falls_back_to_timestamp() {
        let m = SessionMeta {
            started_at: Some("2026-06-13T14:30:22Z".into()),
            ..Default::default()
        };
        assert_eq!(m.title(), "Meeting 2026-06-13 14:30");
        let named = SessionMeta {
            title: Some("Weekly sync".into()),
            ..Default::default()
        };
        assert_eq!(named.title(), "Weekly sync");
        assert_eq!(SessionMeta::default().title(), "Meeting");
    }

    #[test]
    fn render_note_has_frontmatter_and_title_heading() {
        let m = SessionMeta {
            session_id: Some("01J".into()),
            started_at: Some("2026-06-13T14:30:22Z".into()),
            duration_s: Some(1830.0),
            title: None,
            ..Default::default()
        };
        let md = render_note(
            &m,
            "Q3 Launch Sync",
            "## Summary\n- talked".into(),
            "mlx-community/Qwen3.5-4B-MLX-4bit",
        );
        assert!(md.starts_with("---\n"));
        assert!(md.contains("title: \"Q3 Launch Sync\"\n"));
        assert!(md.contains("duration_min: 31\n"));
        assert!(md.contains("session_id: \"01J\"\n"));
        assert!(md.contains("generated_by: minutiae\n"));
        assert!(md.contains("\n# Q3 Launch Sync\n\n"));
        assert!(md.contains("## Summary"));
        assert!(md.ends_with('\n'));
    }

    #[test]
    fn clean_title_normalizes_model_output() {
        assert_eq!(clean_title("Q3 Launch Planning").as_deref(), Some("Q3 Launch Planning"));
        assert_eq!(clean_title("\"Budget Review\".").as_deref(), Some("Budget Review"));
        assert_eq!(clean_title("Title: Weekly Sync").as_deref(), Some("Weekly Sync"));
        assert_eq!(clean_title("## Roadmap Chat\nextra").as_deref(), Some("Roadmap Chat"));
        // Qwen3.5 close-only reasoning leak is stripped before the title.
        assert_eq!(
            clean_title("thinking…\n</think>\nKickoff Meeting").as_deref(),
            Some("Kickoff Meeting")
        );
        assert_eq!(clean_title("   ").as_deref(), None);
    }

    #[test]
    fn build_prompt_marks_empty_notes() {
        let p = build_prompt("Me: hi\nThem: hello\n", "   ");
        assert!(p.contains("Me: hi"));
        assert!(p.contains("(none)"));
        let p2 = build_prompt("Me: hi\n", "remember the budget");
        assert!(p2.contains("remember the budget"));
        assert!(!p2.contains("(none)"));
    }

    #[test]
    fn read_transcript_orders_and_labels() {
        let dir = tempfile::tempdir().unwrap();
        let json = r#"{"schema_version":1,"session_id":"x","segments":[
            {"idx":2,"channel":"them","t0":2.0,"t1":3.0,"text":"world","confidence":0.9,"final":true,"engine":"p"},
            {"idx":0,"channel":"me","t0":0.0,"t1":1.0,"text":"hello","confidence":0.9,"final":true,"engine":"p"},
            {"idx":1,"channel":"me","t0":1.0,"t1":2.0,"text":"  ","confidence":0.9,"final":true,"engine":"p"}
        ]}"#;
        std::fs::write(dir.path().join("transcript.json"), json).unwrap();
        let text = read_transcript(dir.path()).unwrap();
        assert_eq!(text, "Me: hello\nThem: world\n");
    }

    #[test]
    fn write_note_avoids_collision() {
        let dir = tempfile::tempdir().unwrap();
        let a = write_note(dir.path(), "Weekly sync", "# A\n").unwrap();
        let b = write_note(dir.path(), "Weekly sync", "# B\n").unwrap();
        assert_eq!(a.file_name().unwrap(), "Weekly-sync.md");
        assert_eq!(b.file_name().unwrap(), "Weekly-sync-2.md");
        assert_ne!(a, b);
    }

    #[test]
    fn session_meta_missing_file_is_no_session() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            SessionMeta::read(dir.path()),
            Err(LlmError::NoSession)
        ));
    }

    #[test]
    fn transcript_markdown_merges_speaker_turns() {
        let segs = vec![
            Segment { idx: 0, channel: "me".into(), t0: 0.0, t1: 1.0, text: "hello".into(), confidence: 0.9, is_final: true, engine: "p".into() },
            Segment { idx: 1, channel: "me".into(), t0: 1.0, t1: 2.0, text: "there".into(), confidence: 0.9, is_final: true, engine: "p".into() },
            Segment { idx: 2, channel: "them".into(), t0: 65.0, t1: 66.0, text: "hi".into(), confidence: 0.9, is_final: true, engine: "p".into() },
        ];
        let md = render_transcript_markdown(&segs);
        // Consecutive "me" segments merge into one paragraph under one header.
        assert!(md.contains("**Me** · 0:00\n\nhello there\n"));
        // Speaker change starts a new header with its own timestamp (mm:ss).
        assert!(md.contains("**Them** · 1:05\n\nhi\n"));
    }

    #[test]
    fn write_transcript_note_is_idempotent_per_session() {
        let session = tempfile::tempdir().unwrap();
        let vault = tempfile::tempdir().unwrap();
        std::fs::write(
            session.path().join("session.json"),
            r#"{"schema_version":1,"session_id":"01ABC","started_at":"2026-06-25T10:00:00Z"}"#,
        )
        .unwrap();
        std::fs::write(
            session.path().join("transcript.json"),
            r#"{"segments":[{"idx":0,"channel":"me","t0":0.0,"t1":1.0,"text":"hello","confidence":0.9,"final":true,"engine":"p"}]}"#,
        )
        .unwrap();

        let p1 = write_transcript_note(vault.path(), session.path()).unwrap().unwrap();
        let body = std::fs::read_to_string(&p1).unwrap();
        assert!(body.contains("type: transcript\n"));
        assert!(body.contains("session_id: \"01ABC\"\n"));
        assert!(body.contains("# Meeting 2026-06-25 10:00 — Transcript"));
        assert!(body.contains("**Me** · 0:00"));

        // Second export overwrites the same file (no `-2` proliferation).
        let p2 = write_transcript_note(vault.path(), session.path()).unwrap().unwrap();
        assert_eq!(p1, p2);
        let md_count = std::fs::read_dir(vault.path())
            .unwrap()
            .filter(|e| e.as_ref().unwrap().path().extension().map(|x| x == "md").unwrap_or(false))
            .count();
        assert_eq!(md_count, 1);
    }

    #[test]
    fn write_transcript_note_skips_when_empty() {
        let session = tempfile::tempdir().unwrap();
        let vault = tempfile::tempdir().unwrap();
        std::fs::write(
            session.path().join("session.json"),
            r#"{"schema_version":1,"session_id":"01ABC"}"#,
        )
        .unwrap();
        std::fs::write(session.path().join("transcript.json"), r#"{"segments":[]}"#).unwrap();
        assert!(write_transcript_note(vault.path(), session.path()).unwrap().is_none());
    }
}
