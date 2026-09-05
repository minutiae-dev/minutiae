// Svelte 5 runes state for the single capture screen.

import { open } from "../transport";

import {
  cancelEnhance,
  deleteSession,
  enhanceSession,
  getSettings,
  getState,
  isTauri,
  listDevices,
  listenAppError,
  listenLevels,
  listenLlmDone,
  listenLlmError,
  listenLlmProgress,
  listenLlmToken,
  listenModelProgress,
  listenModelReady,
  listenSession,
  listenTranscript,
  listenLlmModelProgress,
  listenLlmModelReady,
  listSessions,
  loadScratchpad,
  openSession,
  getLlmStatus,
  prepareLlm,
  prepareModels,
  revealTranscriptNote,
  saveScratchpad,
  setAsrModel,
  setThinkingMode,
  setVaultDir,
  startSession,
  stopSession,
  type AppErrorPayload,
  type AsrModel,
  type DeviceInfo,
  type LlmProgressPayload,
  type OutputDeviceInfo,
  type ModelProgressPayload,
  type Phase,
  type Segment,
  type SessionStatePayload,
  type SessionSummary,
  type TranscriptSegmentPayload,
  type UnlistenFn,
} from "../ipc";

const SILENCE_DB = -120;
/** Debounce for scratchpad autosave while typing. */
const SCRATCHPAD_SAVE_MS = 700;

/**
 * Split raw model output into reasoning + answer. Qwen3.5 thinking mode streams
 * `reasoning… </think> answer` (the opening `<think>` lives in the prompt, so it
 * may be absent). In instruct mode there are no tags — it's all answer.
 */
function splitThink(
  raw: string,
  thinkingMode: boolean,
  streaming: boolean,
): { thinking: string; answer: string } {
  const close = raw.indexOf("</think>");
  if (close >= 0) {
    let thinking = raw.slice(0, close);
    const open = thinking.indexOf("<think>");
    if (open >= 0) thinking = thinking.slice(open + "<think>".length);
    return {
      thinking: thinking.trim(),
      answer: raw.slice(close + "</think>".length).replace(/^\s+/, ""),
    };
  }
  // No closing tag yet. While a thinking-mode generation streams, everything so
  // far is reasoning; otherwise treat it as the answer.
  if (streaming && thinkingMode) {
    let thinking = raw;
    const open = thinking.indexOf("<think>");
    if (open >= 0) thinking = thinking.slice(open + "<think>".length);
    return { thinking: thinking.replace(/^\s+/, ""), answer: "" };
  }
  return { thinking: "", answer: raw };
}

export class SessionStore {
  phase = $state<Phase>("idle");
  sessionId = $state<string | null>(null);
  devices = $state<DeviceInfo[]>([]);
  /** what the far end plays out of; drives the headset hint (null = unknown) */
  outputDevice = $state<OutputDeviceInfo | null>(null);
  selectedMicUid = $state<string>("");
  /** "them" channel source: "system" (process tap) or an input-device UID. */
  selectedThemSource = $state<string>("system");
  segments = $state<Segment[]>([]);
  levels = $state<{ meDb: number; themDb: number }>({
    meDb: SILENCE_DB,
    themDb: SILENCE_DB,
  });
  modelProgress = $state<ModelProgressPayload | null>(null);
  /** ASR models downloaded + compiled and ready to transcribe. */
  modelsReady = $state(false);
  /** Set when the launch-time model download fails; backs the Retry button. */
  modelError = $state<string | null>(null);
  /** True while a (re)download is running. */
  preparingModels = $state(false);
  lastError = $state<AppErrorPayload | null>(null);
  /** seconds since recording started */
  elapsed = $state(0);
  /** an invoke is in flight */
  busy = $state(false);

  // -- Vault + scratchpad (M2) ----------------------------------------------
  /** absolute path to the notes vault, or null until the user picks one */
  vaultDir = $state<string | null>(null);
  /** the focused session's notes; saved to its scratchpad.md */
  scratchpadText = $state("");
  /** a session is in focus, so notes can be taken/edited */
  notesActive = $state(false);
  /** a scratchpad save is in flight */
  notesSaving = $state(false);
  /** brief "Saved" acknowledgement after a successful save */
  notesSaved = $state(false);

  // -- Enhancement (M2) -----------------------------------------------------
  // The in-flight (or last) enhance, scoped to ONE session via `enhanceSessionId`
  // so it never bleeds onto another meeting you navigate to. At most one runs at
  // a time (the LLM sidecar is single-stream); recording a *different* meeting
  // meanwhile is fine (separate sidecar).
  /** which session the in-flight/last enhance belongs to */
  enhanceSessionId = $state<string | null>(null);
  /** idle → running → done | error; resets to idle on a new enhance */
  enhanceState = $state<"idle" | "running" | "done" | "error">("idle");
  /** model load progress before the first token (null once streaming) */
  enhanceProgress = $state<LlmProgressPayload | null>(null);
  /** raw model output as it streams (may include a <think> reasoning span) */
  enhanceRaw = $state("");
  /** bare file name written to the vault, on success */
  enhancedFile = $state<string | null>(null);
  enhanceError = $state<string | null>(null);
  /** persisted: reason before answering (default false = instruct mode) */
  thinkingMode = $state(false);
  /** persisted (hidden setting): selected on-device ASR model */
  asrModel = $state<AsrModel>("parakeet-tdt-v3");

  // The *viewed* session's already-saved enhanced note (shown when you're not
  // looking at the session currently being enhanced).
  viewedEnhancedMarkdown = $state("");
  viewedEnhancedFile = $state<string | null>(null);

  // -- Enhancement model (on-demand local LLM) ------------------------------
  /** weights are on disk (enhancing won't trigger a multi-GB download) */
  llmDownloaded = $state(false);
  /** model is loaded into the sidecar this session */
  llmReady = $state(false);
  /** cloud enrichment is active (SaaS, signed in) — no local model needed */
  llmCloudActive = $state(false);
  /** a download/load is in flight */
  llmPreparing = $state(false);
  /** download/load progress while preparing (null otherwise) */
  llmPrepProgress = $state<LlmProgressPayload | null>(null);
  llmPrepError = $state<string | null>(null);

  // -- History (Recents) ----------------------------------------------------
  /** past sessions for the left sidebar, newest first */
  sessions = $state<SessionSummary[]>([]);
  /** the session_id highlighted in Recents (live or opened); null = New */
  selectedSessionId = $state<string | null>(null);
  /** which right-pane tab is showing */
  activeTab = $state<"transcript" | "enhanced">("transcript");
  /** an open_session call is in flight */
  openingSession = $state(false);
  /** folder of the session on screen, once it appears in Recents (a live
   *  recording only lands there after Stop refreshes the list) */
  viewedDir = $derived(
    this.sessions.find((s) => s.session_id === this.selectedSessionId)?.dir ?? null,
  );

  /** an enhance is running for SOME session (only one at a time) */
  enhancing = $derived(this.enhanceState === "running");
  /** the session you're viewing is the one being / last enhanced */
  onEnhanceView = $derived(
    this.selectedSessionId !== null &&
      this.selectedSessionId === this.enhanceSessionId,
  );

  // What the Enhanced tab shows for the VIEWED session: the live enhance when
  // you're on its session, otherwise that session's saved note.
  #viewParsed = $derived(
    splitThink(
      this.onEnhanceView ? this.enhanceRaw : this.viewedEnhancedMarkdown,
      this.thinkingMode,
      this.onEnhanceView && this.enhanceState === "running",
    ),
  );
  /** an enhance is streaming for the session you're viewing */
  viewEnhancing = $derived(this.onEnhanceView && this.enhanceState === "running");
  /** enhance state for the viewed session */
  viewEnhanceState = $derived(
    this.onEnhanceView
      ? this.enhanceState
      : this.viewedEnhancedMarkdown
        ? "done"
        : "idle",
  );
  viewEnhanceProgress = $derived(this.onEnhanceView ? this.enhanceProgress : null);
  viewEnhancedFile = $derived(
    this.onEnhanceView ? this.enhancedFile : this.viewedEnhancedFile,
  );
  viewEnhanceError = $derived(this.onEnhanceView ? this.enhanceError : null);
  /** the answer body for the viewed session, reasoning stripped */
  viewEnhancedText = $derived(this.#viewParsed.answer);
  /** the model's reasoning for the viewed session, if any */
  viewThinkingText = $derived(this.#viewParsed.thinking);
  /** reasoning is actively streaming on this view — drives the soundwave */
  viewIsThinking = $derived(
    this.viewEnhancing &&
      this.thinkingMode &&
      this.enhanceRaw.length > 0 &&
      !this.enhanceRaw.includes("</think>"),
  );

  /** last path segment of the vault, for compact display */
  vaultName = $derived(
    this.vaultDir ? (this.vaultDir.split("/").filter(Boolean).at(-1) ?? this.vaultDir) : null,
  );

  isRecording = $derived(this.phase === "recording");
  canPickDevice = $derived(this.phase === "idle" || this.phase === "error");
  /** On speakers the far end is in the room, so the mic picks it up as well as
   *  the tap does. Echo suppression handles it, but it is a safety net working
   *  against a lossy situation — a headset removes the problem instead. Only
   *  shown before recording, and only when the engine is confident. */
  showHeadsetHint = $derived(
    this.outputDevice?.route === "speakers" && this.canPickDevice,
  );
  canStart = $derived(
    (this.phase === "idle" || this.phase === "error") &&
      this.selectedMicUid !== "" &&
      this.modelsReady &&
      !this.busy,
  );
  canStop = $derived(this.phase === "recording" && !this.busy);
  /** a finished session is in focus, a vault is set, and nothing is running */
  canEnhance = $derived(
    this.notesActive &&
      this.vaultDir !== null &&
      this.phase !== "recording" &&
      this.phase !== "starting" &&
      this.phase !== "stopping" &&
      !this.enhancing,
  );

  #t0EpochMs: number | null = null;
  #timer: ReturnType<typeof setInterval> | null = null;
  #unlisteners: UnlistenFn[] = [];
  #initialized = false;
  /** session id whose scratchpad is currently loaded (detects new focus) */
  #notesSessionId: string | null = null;
  #scratchpadTimer: ReturnType<typeof setTimeout> | null = null;
  #savedTimer: ReturnType<typeof setTimeout> | null = null;

  async init(): Promise<void> {
    if (this.#initialized) return;
    this.#initialized = true;

    if (!isTauri()) {
      this.lastError = {
        code: "internal",
        message:
          "No Tauri backend on this page. Run `pnpm dev` from the repo root " +
          "(or `pnpm tauri dev` from app/) — `vite` alone serves the UI " +
          "without the app behind it.",
        fatal: true,
      };
      return;
    }

    // Load Recents first and unawaited: it is a pure filesystem read, while
    // everything below it (listeners, get_state, and above all refreshDevices,
    // which waits on the engine sidecar for up to 10 s while it downloads ASR
    // models at launch) can stall. Queuing the list behind them is what made
    // past meetings look absent on a cold start.
    void this.refreshSessions();

    this.#unlisteners = await Promise.all([
      listenSession((p) => this.#onState(p)),
      listenTranscript((p) => this.#onSegment(p)),
      listenLevels((p) => {
        this.levels = { meDb: p.me_db, themDb: p.them_db };
      }),
      listenModelProgress((p) => {
        // Ignore the silent cached-model preload (no model:ready follows it) —
        // only show the bar during a genuine first-run prepare.
        if (this.modelsReady) return;
        // Keep the bar visible until model:ready; pct cycles 0→100 per stage.
        this.modelProgress = p;
        this.preparingModels = true;
        this.modelError = null;
      }),
      listenModelReady((p) => {
        this.modelsReady = p.ready;
        this.modelProgress = null;
        this.preparingModels = false;
        this.modelError = null;
      }),
      listenAppError((p) => {
        // Route first-run model-download failures to the dedicated, friendlier
        // prep UI (with Retry) instead of the generic error banner.
        if (p.code === "model_download_failed") {
          this.modelError = p.message;
          this.modelProgress = null;
          this.preparingModels = false;
        } else {
          this.lastError = p;
          // An engine stop aborts the in-flight recording; the core backfills it
          // into an openable session, so refresh Recents to surface it.
          void this.refreshSessions();
        }
      }),
      listenLlmProgress((p) => {
        if (this.enhanceState === "running") this.enhanceProgress = p;
      }),
      listenLlmToken((p) => {
        // first token means generation started — drop the model-load bar
        this.enhanceProgress = null;
        this.enhanceRaw += p.text;
      }),
      listenLlmDone((p) => {
        this.enhancedFile = p.file;
        this.enhanceProgress = null;
        this.enhanceState = "done";
        // The note now exists in the vault — reflect it in Recents.
        void this.refreshSessions();
      }),
      listenLlmError((p) => {
        this.enhanceError = p.message;
        this.enhanceProgress = null;
        this.enhanceState = "error";
      }),
      listenLlmModelProgress((p) => {
        this.llmPrepProgress = p;
        this.llmPreparing = true;
        this.llmPrepError = null;
      }),
      listenLlmModelReady((p) => {
        this.llmDownloaded = true;
        this.llmReady = p.ready;
        this.llmPreparing = false;
        this.llmPrepProgress = null;
        this.llmPrepError = null;
      }),
    ]);

    try {
      const settings = await getSettings();
      this.vaultDir = settings.vault_dir;
      this.thinkingMode = settings.thinking_mode;
      this.asrModel = settings.asr_model as AsrModel;
      // Thinking mode is disabled in the UI for now — keep enhancement in
      // instruct mode (the backend prompts/config stay in place for re-enabling
      // later). Normalize any stale persisted `true`.
      if (this.thinkingMode) {
        this.thinkingMode = false;
        void this.setThinkingMode(false);
      }
    } catch (e) {
      console.error("get_settings failed", e);
    }

    try {
      const s = await getState();
      this.#applyState(s.state, s.session_id, s.t0_epoch_ms);
      this.modelsReady = s.models_ready;
      // The core auto-starts the download at launch; reflect that the moment
      // the UI loads, before the first progress event arrives.
      this.preparingModels = !s.models_ready;
      // If models are already ready, clear any stray preload progress so the
      // prep bar never lingers.
      if (s.models_ready) this.modelProgress = null;
    } catch (e) {
      console.error("get_state failed", e);
    }
    await this.refreshDevices();
    await this.refreshLlmStatus();

    // Re-read devices when the user comes back to the window. Without this the
    // headset hint is stale exactly when it matters: it tells you to plug in
    // headphones, you do, and it keeps telling you. Skipped mid-recording,
    // where the device list is fixed for the session anyway.
    const onFocus = () => {
      if (!this.canPickDevice) return;
      void this.refreshDevices();
      // Cheap (one read_dir), and it is how a meeting synced from another
      // machine — or one recorded while this window was in the background —
      // shows up without a restart.
      void this.refreshSessions();
    };
    window.addEventListener("focus", onFocus);
    this.#unlisteners.push(() => window.removeEventListener("focus", onFocus));
  }

  destroy(): void {
    for (const un of this.#unlisteners) un();
    this.#unlisteners = [];
    this.#initialized = false;
    this.#stopTimer();
    if (this.#scratchpadTimer !== null) clearTimeout(this.#scratchpadTimer);
    if (this.#savedTimer !== null) clearTimeout(this.#savedTimer);
  }

  async refreshDevices(): Promise<void> {
    try {
      const list = await listDevices();
      this.devices = list.items;
      this.outputDevice = list.output;
      const stillThere = this.devices.some((d) => d.uid === this.selectedMicUid);
      if (!this.selectedMicUid || !stillThere) {
        this.selectedMicUid =
          this.devices.find((d) => d.is_default)?.uid ??
          this.devices[0]?.uid ??
          "";
      }
      // If the chosen "them" device vanished, fall back to system audio.
      if (
        this.selectedThemSource !== "system" &&
        !this.devices.some((d) => d.uid === this.selectedThemSource)
      ) {
        this.selectedThemSource = "system";
      }
    } catch (e) {
      this.lastError = {
        code: "internal",
        message: `Could not list input devices: ${e}`,
        fatal: false,
      };
    }
  }

  async start(): Promise<void> {
    if (!this.canStart) return;
    this.busy = true;
    this.lastError = null;
    try {
      const p = await startSession(this.selectedMicUid, this.selectedThemSource);
      this.#onState(p);
    } catch (e) {
      this.lastError = { code: "internal", message: String(e), fatal: false };
    } finally {
      this.busy = false;
    }
  }

  async stop(): Promise<void> {
    if (!this.canStop) return;
    this.busy = true;
    try {
      const p = await stopSession();
      this.#onState(p);
      // The finished session now has a session.json — surface it in Recents.
      await this.refreshSessions();
    } catch (e) {
      this.lastError = { code: "internal", message: String(e), fatal: false };
    } finally {
      this.busy = false;
    }
  }

  dismissError(): void {
    this.lastError = null;
  }

  /** Retry a failed launch-time model download. */
  async retryPrepare(): Promise<void> {
    if (this.preparingModels || this.modelsReady) return;
    this.modelError = null;
    this.preparingModels = true;
    try {
      await prepareModels();
    } catch (e) {
      // A failure also arrives via app:error → modelError; this is a fallback.
      this.modelError = String(e);
      this.preparingModels = false;
    }
  }

  /** Open the native folder picker and persist the chosen vault. */
  async pickVault(): Promise<void> {
    try {
      const picked = await open({
        directory: true,
        multiple: false,
        title: "Choose your notes vault",
        defaultPath: this.vaultDir ?? undefined,
      });
      if (typeof picked === "string") {
        const s = await setVaultDir(picked);
        this.vaultDir = s.vault_dir;
      }
    } catch (e) {
      this.lastError = {
        code: "internal",
        message: `Could not set the vault folder: ${e}`,
        fatal: false,
      };
    }
  }

  /** Debounced autosave; call on every keystroke. */
  queueScratchpadSave(): void {
    this.notesSaved = false;
    if (this.#scratchpadTimer !== null) clearTimeout(this.#scratchpadTimer);
    this.#scratchpadTimer = setTimeout(() => {
      void this.#saveScratchpadNow();
    }, SCRATCHPAD_SAVE_MS);
  }

  /** Flush a pending save immediately (e.g. on blur or before enhancing). */
  flushScratchpadSave(): Promise<void> {
    if (this.#scratchpadTimer !== null) {
      clearTimeout(this.#scratchpadTimer);
      this.#scratchpadTimer = null;
    }
    return this.#saveScratchpadNow();
  }

  /** Enhance the focused session into a Markdown note in the vault. */
  async enhance(): Promise<void> {
    if (!this.canEnhance) return;
    // Never silently kick off a multi-GB download: the local model must be on
    // disk first (the UI shows a download card when it isn't). Cloud enrichment
    // needs no local model, so it's exempt.
    if (!this.llmDownloaded && !this.llmCloudActive) {
      this.activeTab = "enhanced";
      return;
    }
    // Make sure the model reads the latest notes, not a debounced-stale copy.
    await this.flushScratchpadSave();
    // Scope this enhance to the session in focus so its stream only ever shows
    // on that meeting, even if you navigate away or record another one.
    this.enhanceSessionId = this.selectedSessionId;
    this.enhanceState = "running";
    this.enhanceProgress = null;
    this.enhanceRaw = "";
    this.enhancedFile = null;
    this.enhanceError = null;
    // Reveal the output as it streams.
    this.activeTab = "enhanced";
    try {
      const path = await enhanceSession();
      if (path === "") {
        // cancelled — back to idle, discard the partial stream; fall back to the
        // session's saved note (if any).
        this.enhanceState = "idle";
        this.enhanceRaw = "";
        this.enhanceProgress = null;
        this.enhanceSessionId = null;
      }
      // success is finalized by the llm:done listener (sets file + state)
    } catch (e) {
      // also arrives via llm:error (set on another tick); this is the fallback
      // if that listener didn't fire. Cast defeats control-flow narrowing — the
      // async listener may have already set "error".
      if ((this.enhanceState as string) !== "error") {
        this.enhanceError = String(e);
        this.enhanceProgress = null;
        this.enhanceState = "error";
      }
    }
  }

  /** Cancel an in-flight enhancement. */
  async cancelEnhance(): Promise<void> {
    if (!this.enhancing) return;
    try {
      await cancelEnhance();
    } catch (e) {
      console.error("cancel_enhance failed", e);
    }
  }

  /** Dismiss the enhancement result/error panel. */
  dismissEnhance(): void {
    if (this.enhancing) return;
    this.enhanceState = "idle";
    this.enhanceRaw = "";
    this.enhancedFile = null;
    this.enhanceError = null;
    this.enhanceProgress = null;
  }

  /** Toggle thinking mode (persisted); applies to the next enhance. */
  async setThinkingMode(on: boolean): Promise<void> {
    this.thinkingMode = on;
    try {
      await setThinkingMode(on);
    } catch (e) {
      console.error("set_thinking_mode failed", e);
    }
  }

  /**
   * Select the on-device ASR model (persisted; hidden setting). Takes effect on
   * the next capture start and may trigger a one-time model download.
   */
  async setAsrModel(model: AsrModel): Promise<void> {
    const previous = this.asrModel;
    this.asrModel = model;
    try {
      await setAsrModel(model);
    } catch (e) {
      console.error("set_asr_model failed", e);
      this.asrModel = previous;
    }
  }

  /** Refresh whether the enhancement model is downloaded / loaded. */
  async refreshLlmStatus(): Promise<void> {
    try {
      const s = await getLlmStatus();
      this.llmDownloaded = s.downloaded;
      this.llmReady = s.ready;
      this.llmCloudActive = s.cloud_active;
    } catch (e) {
      console.error("get_llm_status failed", e);
    }
  }

  /** Download + load the enhancement model on demand (user-triggered). */
  async prepareLlm(): Promise<void> {
    if (this.llmPreparing) return;
    this.llmPreparing = true;
    this.llmPrepError = null;
    this.llmPrepProgress = null;
    try {
      await prepareLlm();
      // Belt-and-suspenders: the llm:model_ready listener also sets these.
      this.llmDownloaded = true;
      this.llmReady = true;
    } catch (e) {
      this.llmPrepError = String(e);
    } finally {
      this.llmPreparing = false;
      this.llmPrepProgress = null;
    }
  }

  // -- History (Recents) ----------------------------------------------------

  /** Reload the past-sessions list for the sidebar. */
  async refreshSessions(): Promise<void> {
    try {
      this.sessions = await listSessions();
    } catch (e) {
      // Don't silently strand the user with an empty Recents list that looks
      // like "no meetings" when the read actually failed.
      console.error("list_sessions failed", e);
      this.lastError = {
        code: "internal",
        message: `Could not load your past meetings: ${e}`,
        fatal: false,
      };
    }
  }

  /** Open a past session from Recents into the panes (read-only transcript,
   *  editable notes, its enhanced note). No-op while a recording is running. */
  async openPastSession(s: SessionSummary): Promise<void> {
    if (this.phase === "recording" || this.phase === "starting" || this.phase === "stopping") {
      return;
    }
    if (this.openingSession) return;
    this.openingSession = true;
    try {
      const detail = await openSession(s.dir);
      this.#notesSessionId = detail.session_id;
      this.sessionId = detail.session_id;
      this.selectedSessionId = detail.session_id;
      this.segments = detail.segments;
      this.scratchpadText = detail.scratchpad;
      this.notesActive = true;
      this.notesSaved = false;
      // Show this session's saved note. Don't touch the in-flight enhance state
      // (it belongs to whatever session is being enhanced); the view derives
      // which to show via `onEnhanceView`.
      this.viewedEnhancedMarkdown = detail.enhanced_markdown ?? "";
      this.viewedEnhancedFile = detail.enhanced_file;
      this.activeTab =
        detail.session_id === this.enhanceSessionId || detail.enhanced_markdown
          ? "enhanced"
          : "transcript";
    } catch (e) {
      this.lastError = {
        code: "internal",
        message: `Could not open that session: ${e}`,
        fatal: false,
      };
    } finally {
      this.openingSession = false;
    }
  }

  /** Delete a past session (folder + its enhanced note). No-op while a capture
   *  is running. Resets the panes if the deleted session was the open one. */
  async deleteSession(s: SessionSummary): Promise<void> {
    if (this.phase === "recording" || this.phase === "starting" || this.phase === "stopping") {
      return;
    }
    try {
      await deleteSession(s.dir);
      if (this.selectedSessionId === s.session_id) this.newMeeting();
      await this.refreshSessions();
    } catch (e) {
      this.lastError = {
        code: "internal",
        message: `Could not delete that meeting: ${e}`,
        fatal: false,
      };
    }
  }

  /** Show the transcript's Markdown file in Finder. Exports it to the vault
   *  first if this session hasn't written one yet. */
  async revealTranscript(): Promise<void> {
    const dir = this.viewedDir;
    if (!dir) return;
    try {
      await revealTranscriptNote(dir);
    } catch (e) {
      this.lastError = {
        code: "internal",
        message: `Could not show the transcript file: ${e}`,
        fatal: false,
      };
    }
  }

  /** Clear the panes for a fresh capture (the "New" button). Allowed while an
   *  enhance runs in the background — that keeps streaming to its own session. */
  newMeeting(): void {
    if (this.phase === "recording" || this.phase === "starting" || this.phase === "stopping") {
      return;
    }
    this.#notesSessionId = null;
    this.sessionId = null;
    this.selectedSessionId = null;
    this.segments = [];
    this.scratchpadText = "";
    this.notesActive = false;
    this.notesSaved = false;
    // Clear only the viewed note; leave any in-flight enhance running.
    this.viewedEnhancedMarkdown = "";
    this.viewedEnhancedFile = null;
    this.activeTab = "transcript";
  }

  async #saveScratchpadNow(): Promise<void> {
    if (!this.notesActive) return;
    this.notesSaving = true;
    try {
      await saveScratchpad(this.scratchpadText);
      this.notesSaved = true;
      if (this.#savedTimer !== null) clearTimeout(this.#savedTimer);
      this.#savedTimer = setTimeout(() => {
        this.notesSaved = false;
      }, 1500);
    } catch (e) {
      this.lastError = {
        code: "internal",
        message: `Could not save notes: ${e}`,
        fatal: false,
      };
    } finally {
      this.notesSaving = false;
    }
  }

  /** Load the focused session's notes into the editor. */
  async #focusNotes(): Promise<void> {
    this.notesActive = true;
    this.scratchpadText = "";
    this.notesSaved = false;
    // A new (recording) session is in focus and has no enhanced note yet. Clear
    // only the *viewed* note — leave any in-flight enhance (for another session)
    // running; its stream stays hidden because this isn't its session.
    this.viewedEnhancedMarkdown = "";
    this.viewedEnhancedFile = null;
    try {
      this.scratchpadText = await loadScratchpad();
    } catch (e) {
      console.error("load_scratchpad failed", e);
    }
  }

  #onState(p: SessionStatePayload): void {
    this.#applyState(p.state, p.session_id, p.t0_epoch_ms);
  }

  #applyState(
    phase: Phase,
    sessionId: string | null,
    t0EpochMs: number | null,
  ): void {
    if (sessionId && sessionId !== this.sessionId) {
      // a new session began — drop the previous transcript
      this.segments = [];
    }
    // A new session is now in focus: load its (empty) scratchpad. Latches
    // `notesActive` true so notes stay editable after Stop (sessionId → null)
    // until the next session starts.
    if (sessionId && sessionId !== this.#notesSessionId) {
      this.#notesSessionId = sessionId;
      // A live session takes over the panes: highlight it in Recents and show
      // the transcript tab as it streams in.
      this.selectedSessionId = sessionId;
      this.activeTab = "transcript";
      this.#focusNotes();
    }
    this.phase = phase;
    this.sessionId = sessionId;
    this.#t0EpochMs = t0EpochMs;

    if (phase === "recording") {
      this.modelProgress = null;
      this.#startTimer();
    } else {
      this.#stopTimer();
      if (phase === "idle" || phase === "error") {
        this.levels = { meDb: SILENCE_DB, themDb: SILENCE_DB };
      }
    }
  }

  #onSegment(p: TranscriptSegmentPayload): void {
    if (this.sessionId && p.session_id !== this.sessionId) return;
    const i = this.segments.findIndex((s) => s.idx === p.segment.idx);
    if (i >= 0) {
      this.segments[i] = p.segment;
    } else {
      this.segments.push(p.segment);
    }
  }

  #startTimer(): void {
    this.#stopTimer();
    const base = this.#t0EpochMs ?? Date.now();
    const tick = () => {
      this.elapsed = Math.max(0, (Date.now() - base) / 1000);
    };
    tick();
    this.#timer = setInterval(tick, 1000);
  }

  #stopTimer(): void {
    if (this.#timer !== null) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
  }
}

export const session = new SessionStore();
