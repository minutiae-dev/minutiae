// Typed wrappers over Tauri invoke/listen.
//
// The shapes here are hand-mirrored from the Rust core:
//   - commands:  app/src-tauri/src/commands.rs
//   - events:    app/src-tauri/src/events.rs
//   - protocol:  app/src-tauri/src/protocol.rs (docs/protocol/sidecar-ipc-v1.md)
// Change them together.

import { invoke, listen, fixtureMode } from "./transport";
import { type UnlistenFn } from "@tauri-apps/api/event";

/**
 * False when the page is served outside the Tauri webview (e.g. `vite` run
 * directly and opened in a browser) — there is no backend to invoke then.
 */
export function isTauri(): boolean {
  return fixtureMode || "__TAURI_INTERNALS__" in window;
}

// ---------------------------------------------------------------------------
// Types

export type Phase = "idle" | "starting" | "recording" | "stopping" | "error";

/** "me" | "them" today; M4 adds "them:spk1"-style sub-labels. */
export type Channel = "me" | "them" | (string & {});

export interface DeviceInfo {
  uid: string;
  name: string;
  sample_rate: number;
  is_default: boolean;
}

/**
 * The device the far end plays out of. `route` is the engine's advisory read on
 * whether that audio also reaches the mic through the air — "unknown" whenever
 * it can't tell, in which case the UI says nothing.
 */
export interface OutputDeviceInfo {
  name: string;
  transport: string;
  route: "speakers" | "headphones" | "unknown";
}

export interface DeviceList {
  items: DeviceInfo[];
  output: OutputDeviceInfo | null;
}

export interface Segment {
  idx: number;
  channel: Channel;
  /** seconds from session start */
  t0: number;
  t1: number;
  text: string;
  /** 0..1; -1 if unavailable */
  confidence: number;
  /** non-final segments may be re-emitted with the same idx; replace in place */
  final: boolean;
  engine: string;
}

export interface SessionStatePayload {
  state: Phase;
  session_id: string | null;
  /** wall-clock anchor for session-relative seconds; null until recording */
  t0_epoch_ms: number | null;
}

export interface TranscriptSegmentPayload {
  session_id: string;
  segment: Segment;
}

export interface LevelsPayload {
  /** dBFS, <= 0; -120 = silence */
  me_db: number;
  them_db: number;
}

export interface ModelProgressPayload {
  pct: number;
  stage: "downloading" | "compiling" | (string & {});
}

export interface ModelReadyPayload {
  ready: boolean;
}

export interface AppErrorPayload {
  code: string;
  message: string;
  fatal: boolean;
}

export interface AppStateSnapshot {
  state: Phase;
  session_id: string | null;
  t0_epoch_ms: number | null;
  models_ready: boolean;
}

/** On-device ASR model ids (hidden setting). */
export type AsrModel =
  | "parakeet-tdt-v3"
  | "nemotron-streaming-ml"
  | "nemotron-streaming-en";

export interface Settings {
  schema_version: number;
  /** absolute path to the user's notes vault; null until chosen */
  vault_dir: string | null;
  /** enhancement reasons before answering when true (default false = instruct) */
  thinking_mode: boolean;
  /** selected ASR model; "parakeet-tdt-v3" by default */
  asr_model: AsrModel | (string & {});
}

export interface LlmProgressPayload {
  pct: number;
  stage: "downloading" | "loading" | (string & {});
}

export interface LlmTokenPayload {
  text: string;
}

export interface LlmDonePayload {
  /** absolute path of the written `<Title>.md` */
  path: string;
  /** bare file name, for a compact toast */
  file: string;
  tokens_per_s: number;
}

export interface LlmErrorPayload {
  message: string;
}

export interface LlmModelReadyPayload {
  ready: boolean;
}

/** Whether the enhancement model is on disk and/or loaded. */
export interface LlmStatus {
  downloaded: boolean;
  ready: boolean;
  /** cloud enrichment is the active transport (SaaS, signed in); false in OSS */
  cloud_active: boolean;
}

/** One row in the Recents sidebar. */
export interface SessionSummary {
  session_id: string;
  /** absolute path of the session folder */
  dir: string;
  title: string;
  started_at: string | null;
  duration_s: number | null;
  has_enhanced: boolean;
}

/** Everything needed to display a selected (live or past) session. */
export interface SessionDetail {
  session_id: string;
  dir: string;
  title: string;
  started_at: string | null;
  duration_s: number | null;
  segments: Segment[];
  scratchpad: string;
  /** enhanced note body (frontmatter stripped), if one exists */
  enhanced_markdown: string | null;
  enhanced_file: string | null;
}

// ---------------------------------------------------------------------------
// Commands

export function listDevices(): Promise<DeviceList> {
  return invoke<DeviceList>("list_devices");
}

/**
 * Start a session. `themSource` selects the "them" channel: "system" (the
 * system-audio process tap) or an input-device UID to capture directly.
 */
export function startSession(
  micUid: string,
  themSource: string,
): Promise<SessionStatePayload> {
  return invoke<SessionStatePayload>("start_session", { micUid, themSource });
}

export function stopSession(): Promise<SessionStatePayload> {
  return invoke<SessionStatePayload>("stop_session");
}

/** Retry the launch-time model download after a failure. */
export function prepareModels(): Promise<void> {
  return invoke<void>("prepare_models");
}

export function getState(): Promise<AppStateSnapshot> {
  return invoke<AppStateSnapshot>("get_state");
}

export function getSettings(): Promise<Settings> {
  return invoke<Settings>("get_settings");
}

/** Persist the vault folder; validated server-side to be an existing dir. */
export function setVaultDir(dir: string): Promise<Settings> {
  return invoke<Settings>("set_vault_dir", { dir });
}

/** Toggle thinking mode for enhancement (persisted). */
export function setThinkingMode(on: boolean): Promise<Settings> {
  return invoke<Settings>("set_thinking_mode", { on });
}

/** Select the on-device ASR model (hidden setting; persisted, validated server-side). */
export function setAsrModel(model: AsrModel): Promise<Settings> {
  return invoke<Settings>("set_asr_model", { model });
}

/** Save the focused session's notes to its `scratchpad.md`. */
export function saveScratchpad(text: string): Promise<void> {
  return invoke<void>("save_scratchpad", { text });
}

/** Load the focused session's `scratchpad.md` ("" if none). */
export function loadScratchpad(): Promise<string> {
  return invoke<string>("load_scratchpad");
}

/**
 * Enhance the focused session into a Markdown note in the vault. Streams
 * `llm:progress`/`llm:token` and resolves with the written file path on
 * `llm:done`; rejects with the error message on failure.
 */
export function enhanceSession(): Promise<string> {
  return invoke<string>("enhance_session");
}

/** Cancel an in-flight enhancement (no-op if none). */
export function cancelEnhance(): Promise<void> {
  return invoke<void>("cancel_enhance");
}

/** Whether the enhancement model is downloaded and/or loaded. */
export function getLlmStatus(): Promise<LlmStatus> {
  return invoke<LlmStatus>("get_llm_status");
}

/**
 * Download (if needed) and load the enhancement model on demand. Streams
 * `llm:model_progress` and resolves once `llm:model_ready` fires.
 */
export function prepareLlm(): Promise<void> {
  return invoke<void>("prepare_llm");
}

/** List past sessions for the Recents sidebar, newest first. */
export function listSessions(): Promise<SessionSummary[]> {
  return invoke<SessionSummary[]>("list_sessions");
}

/**
 * Open a past session: focus it (so its notes can be edited / re-enhanced) and
 * return its transcript, notes, and enhanced note. Rejects while recording.
 */
export function openSession(dir: string): Promise<SessionDetail> {
  return invoke<SessionDetail>("open_session", { dir });
}

/**
 * Delete a past session: removes its folder and the enhanced note it wrote to
 * the vault. Rejects while a recording is in flight.
 */
export function deleteSession(dir: string): Promise<void> {
  return invoke<void>("delete_session", { dir });
}

/**
 * Reveal a session's transcript Markdown in Finder, exporting it to the vault
 * first if it isn't there yet. Rejects when no vault is set.
 */
export function revealTranscriptNote(dir: string): Promise<void> {
  return invoke<void>("reveal_transcript_note", { dir });
}

// ---------------------------------------------------------------------------
// Events

export const EVENT_SESSION_STATE = "session:state";
export const EVENT_TRANSCRIPT_SEGMENT = "transcript:segment";
export const EVENT_LEVELS_UPDATE = "levels:update";
export const EVENT_MODEL_PROGRESS = "model:progress";
export const EVENT_MODEL_READY = "model:ready";
export const EVENT_APP_ERROR = "app:error";
export const EVENT_LLM_PROGRESS = "llm:progress";
export const EVENT_LLM_TOKEN = "llm:token";
export const EVENT_LLM_DONE = "llm:done";
export const EVENT_LLM_ERROR = "llm:error";
export const EVENT_LLM_MODEL_PROGRESS = "llm:model_progress";
export const EVENT_LLM_MODEL_READY = "llm:model_ready";

export function listenSession(
  cb: (payload: SessionStatePayload) => void,
): Promise<UnlistenFn> {
  return listen<SessionStatePayload>(EVENT_SESSION_STATE, (e) => cb(e.payload));
}

export function listenTranscript(
  cb: (payload: TranscriptSegmentPayload) => void,
): Promise<UnlistenFn> {
  return listen<TranscriptSegmentPayload>(EVENT_TRANSCRIPT_SEGMENT, (e) =>
    cb(e.payload),
  );
}

export function listenLevels(
  cb: (payload: LevelsPayload) => void,
): Promise<UnlistenFn> {
  return listen<LevelsPayload>(EVENT_LEVELS_UPDATE, (e) => cb(e.payload));
}

export function listenModelProgress(
  cb: (payload: ModelProgressPayload) => void,
): Promise<UnlistenFn> {
  return listen<ModelProgressPayload>(EVENT_MODEL_PROGRESS, (e) =>
    cb(e.payload),
  );
}

export function listenModelReady(
  cb: (payload: ModelReadyPayload) => void,
): Promise<UnlistenFn> {
  return listen<ModelReadyPayload>(EVENT_MODEL_READY, (e) => cb(e.payload));
}

export function listenAppError(
  cb: (payload: AppErrorPayload) => void,
): Promise<UnlistenFn> {
  return listen<AppErrorPayload>(EVENT_APP_ERROR, (e) => cb(e.payload));
}

export function listenLlmProgress(
  cb: (payload: LlmProgressPayload) => void,
): Promise<UnlistenFn> {
  return listen<LlmProgressPayload>(EVENT_LLM_PROGRESS, (e) => cb(e.payload));
}

export function listenLlmToken(
  cb: (payload: LlmTokenPayload) => void,
): Promise<UnlistenFn> {
  return listen<LlmTokenPayload>(EVENT_LLM_TOKEN, (e) => cb(e.payload));
}

export function listenLlmDone(
  cb: (payload: LlmDonePayload) => void,
): Promise<UnlistenFn> {
  return listen<LlmDonePayload>(EVENT_LLM_DONE, (e) => cb(e.payload));
}

export function listenLlmError(
  cb: (payload: LlmErrorPayload) => void,
): Promise<UnlistenFn> {
  return listen<LlmErrorPayload>(EVENT_LLM_ERROR, (e) => cb(e.payload));
}

export function listenLlmModelProgress(
  cb: (payload: LlmProgressPayload) => void,
): Promise<UnlistenFn> {
  return listen<LlmProgressPayload>(EVENT_LLM_MODEL_PROGRESS, (e) =>
    cb(e.payload),
  );
}

export function listenLlmModelReady(
  cb: (payload: LlmModelReadyPayload) => void,
): Promise<UnlistenFn> {
  return listen<LlmModelReadyPayload>(EVENT_LLM_MODEL_READY, (e) =>
    cb(e.payload),
  );
}

export type { UnlistenFn };
