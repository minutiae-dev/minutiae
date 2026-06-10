// Typed wrappers over Tauri invoke/listen.
//
// The shapes here are hand-mirrored from the Rust core:
//   - commands:  app/src-tauri/src/commands.rs
//   - events:    app/src-tauri/src/events.rs
//   - protocol:  app/src-tauri/src/protocol.rs (docs/protocol/sidecar-ipc-v1.md)
// Change them together.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

/**
 * False when the page is served outside the Tauri webview (e.g. `vite` run
 * directly and opened in a browser) — there is no backend to invoke then.
 */
export function isTauri(): boolean {
  return "__TAURI_INTERNALS__" in window;
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

// ---------------------------------------------------------------------------
// Commands

export function listDevices(): Promise<DeviceInfo[]> {
  return invoke<DeviceInfo[]>("list_devices");
}

export function startSession(micUid: string): Promise<SessionStatePayload> {
  return invoke<SessionStatePayload>("start_session", { micUid });
}

export function stopSession(): Promise<SessionStatePayload> {
  return invoke<SessionStatePayload>("stop_session");
}

export function getState(): Promise<AppStateSnapshot> {
  return invoke<AppStateSnapshot>("get_state");
}

// ---------------------------------------------------------------------------
// Events

export const EVENT_SESSION_STATE = "session:state";
export const EVENT_TRANSCRIPT_SEGMENT = "transcript:segment";
export const EVENT_LEVELS_UPDATE = "levels:update";
export const EVENT_MODEL_PROGRESS = "model:progress";
export const EVENT_APP_ERROR = "app:error";

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

export function listenAppError(
  cb: (payload: AppErrorPayload) => void,
): Promise<UnlistenFn> {
  return listen<AppErrorPayload>(EVENT_APP_ERROR, (e) => cb(e.payload));
}

export type { UnlistenFn };
