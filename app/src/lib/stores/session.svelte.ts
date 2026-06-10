// Svelte 5 runes state for the single capture screen.

import {
  getState,
  isTauri,
  listDevices,
  listenAppError,
  listenLevels,
  listenModelProgress,
  listenSession,
  listenTranscript,
  startSession,
  stopSession,
  type AppErrorPayload,
  type DeviceInfo,
  type ModelProgressPayload,
  type Phase,
  type Segment,
  type SessionStatePayload,
  type TranscriptSegmentPayload,
  type UnlistenFn,
} from "../ipc";

const SILENCE_DB = -120;

export class SessionStore {
  phase = $state<Phase>("idle");
  sessionId = $state<string | null>(null);
  devices = $state<DeviceInfo[]>([]);
  selectedMicUid = $state<string>("");
  segments = $state<Segment[]>([]);
  levels = $state<{ meDb: number; themDb: number }>({
    meDb: SILENCE_DB,
    themDb: SILENCE_DB,
  });
  modelProgress = $state<ModelProgressPayload | null>(null);
  lastError = $state<AppErrorPayload | null>(null);
  /** seconds since recording started */
  elapsed = $state(0);
  /** an invoke is in flight */
  busy = $state(false);

  isRecording = $derived(this.phase === "recording");
  canPickDevice = $derived(this.phase === "idle" || this.phase === "error");
  canStart = $derived(
    (this.phase === "idle" || this.phase === "error") &&
      this.selectedMicUid !== "" &&
      !this.busy,
  );
  canStop = $derived(this.phase === "recording" && !this.busy);

  #t0EpochMs: number | null = null;
  #timer: ReturnType<typeof setInterval> | null = null;
  #unlisteners: UnlistenFn[] = [];
  #initialized = false;

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

    this.#unlisteners = await Promise.all([
      listenSession((p) => this.#onState(p)),
      listenTranscript((p) => this.#onSegment(p)),
      listenLevels((p) => {
        this.levels = { meDb: p.me_db, themDb: p.them_db };
      }),
      listenModelProgress((p) => {
        this.modelProgress = p.pct >= 100 ? null : p;
      }),
      listenAppError((p) => {
        this.lastError = p;
      }),
    ]);

    try {
      const s = await getState();
      this.#applyState(s.state, s.session_id, s.t0_epoch_ms);
    } catch (e) {
      console.error("get_state failed", e);
    }
    await this.refreshDevices();
  }

  destroy(): void {
    for (const un of this.#unlisteners) un();
    this.#unlisteners = [];
    this.#initialized = false;
    this.#stopTimer();
  }

  async refreshDevices(): Promise<void> {
    try {
      this.devices = await listDevices();
      const stillThere = this.devices.some((d) => d.uid === this.selectedMicUid);
      if (!this.selectedMicUid || !stillThere) {
        this.selectedMicUid =
          this.devices.find((d) => d.is_default)?.uid ??
          this.devices[0]?.uid ??
          "";
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
      const p = await startSession(this.selectedMicUid);
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
    } catch (e) {
      this.lastError = { code: "internal", message: String(e), fatal: false };
    } finally {
      this.busy = false;
    }
  }

  dismissError(): void {
    this.lastError = null;
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
