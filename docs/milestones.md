# Milestones

## M1 — Capture + live transcript (weeks 1–3) — IN PROGRESS

From `pnpm dev`: pick mic → start (<1 s) → live two-channel ("Me"/"Them") transcript with level meters during a real Zoom and Meet-in-Chrome call on AirPods → stop → session folder with valid `session.json`, `transcript.json`, two playable Opus/CAF files. Zero transcript text during silence. Sidecar crash mid-session leaves a readable partial transcript. Risk matrix (apps × audio routes × hot-switch/drift) has no red cells in the Zoom/Meet/AirPods rows.

Checkpoints:
- **A** — UI button → sidecar → UI event round-trip (IPC plumbing).
- **B (risk gate)** — record a Zoom call; both WAVs non-empty, clap-test cross-channel alignment ≤ 50 ms. If process taps fail → re-route to ScreenCaptureKit audio behind the same `SystemAudioTap` interface.
- **C** — YouTube in Safari while talking: correct channel attribution, zero segments during 60 s of silence, start < 1 s with TCC pre-granted.

## M2 — Scratchpad + enhancement — IN PROGRESS

Scratchpad editor saved to `scratchpad.md`; enhancement pipeline merges scratchpad + transcript → Markdown + YAML frontmatter into the user-chosen vault folder. The session format is its input contract.

**Settled architecture (local sidecar first):** a single Rust `LlmBackend` seam with **one implementation for now** — a lazily-spawned `minutiae-llm` sidecar (NDJSON over stdio, same envelope/handshake/respawn pattern as the engine sidecar) running **MLX** on Apple Silicon. First model: `mlx-community/Qwen3.5-4B-OptiQ-4bit`. The LLM sidecar starts on first *Enhance* and the model loads on demand (then unloads) to protect the <250 MB idle target. The BYO OpenAI-compatible HTTP backend and a `llama-cpp-2` (Windows/portable) backend are deferred behind the same seam — they slot in without changing the trait. Protocol doc: `docs/protocol/llm-ipc-v1.md` (mirrored in `protocol.rs` + the new sidecar's `Messages.swift`).

Build sequence:
1. ✅ **Vault folder picker** + persisted `settings.json` (schema_version 1) — `set_vault_dir`/`get_settings`, validated dir, atomic write.
2. ✅ **Scratchpad editor** → `scratchpad.md` (atomic, debounced autosave), focused on the active/most-recent session.
3. ✅ **MLX spike** (`llm-engine/`, see its README) — loads `mlx-community/Qwen3.5-4B-MLX-4bit` via mlx-swift-lm and streams a coherent completion on M3 (4.7 s load, ~17 tok/s Debug). Retired the real risks: **needs Xcode 16.4+ / Swift 6.1.2** (qwen3_5 lives in mlx-swift-lm 3.x, tools 6.1) and **must build via `xcodebuild -skipMacroValidation`** (SwiftPM can't compile MLX's Metal shaders → `default.metallib`). Qwen3.5 is a **reasoning model** — set `enable_thinking=false` for enhancement. (Note: `Qwen3.5-…-OptiQ-4bit` was the original pick but uses a custom quant + the same multimodal arch; the standard `-MLX-4bit` is what loads.)
4. ✅ **`minutiae-llm` sidecar** + `llm-ipc-v1` protocol + `LocalSidecar` backend. Build chain per `llm-engine/README.md` (xcodebuild, metallib colocated beside the binary in `mlx-swift_Cmlx.bundle`).
   - ✅ `docs/protocol/llm-ipc-v1.md` — IPC spec (sidecar = pure completion engine; core assembles prompt + writes vault `.md`).
   - ✅ Swift `minutiae-llm` sidecar — Messages/StdioTransport/ModelRunner(actor, lazy load, `/no_think`, max-tokens cap, cooperative cancel)/LLMController(serial loop, detached gen, single active). Builds; hello/ping/shutdown smoke-tested.
   - ✅ Rust `llm_protocol.rs` mirror — 8 round-trip/wire-shape tests pass.
   - ✅ Rust `LlmBackend` trait + `LocalSidecar` (`llm.rs`): lazy spawn, `hello` handshake, stdout reader routing streamed `llm_token`/`llm_done`/`error` to the active generation; cancel discards the partial note.
   - ✅ `scripts/build-llm-sidecar.sh` — xcodebuild → installs binary **+** metallib bundle into `target/<profile>/` (so `pnpm dev` can spawn it) and stashes a copy in `binaries/`. Kept out of the dev `beforeDevCommand` (the MLX build is slow). Capability entries added. **Bundling into the signed `.app` (externalBin + tauri#11992 signing) is deferred to M5.**
5. ✅ **Enhancement pipeline** (`LlmManager` + `enhance_session`/`cancel_enhance` commands + `EnhancePanel.svelte`) — reads `transcript.json` + `scratchpad.md`, assembles a `/no_think` summarization prompt, streams tokens to the UI (`llm:progress`/`llm:token`/`llm:done`/`llm:error`), strips any leaked `<think>` block, and writes `<Title>.md` with YAML frontmatter from `session.json` into the vault (collision-safe filenames). Pure helpers (prompt/slug/frontmatter/transcript-render) unit-tested.

   **End-to-end smoke test still pending:** run `scripts/build-llm-sidecar.sh release`, then `pnpm dev`, finish a session with a vault set, and click *Enhance* to confirm the first-run model download → stream → vault write path on-device.

## M3 — Templates + calendar

Templates as Markdown files (frontmatter + prompt body) in a `templates/` dir, per-template model override. EventKit read-only (a `calendar` message family in the Swift sidecar) prefills `title`/`calendar_event` in `session.json`. Optional mic AEC (`setVoiceProcessingEnabled`) to cut echo bleed.

## M4 — Search + diarization refinement

`rusqlite` + FTS5 index over transcripts/notes — derived data, rebuildable, never authoritative (`sqlite-vec` later for semantic search). Pyannote-via-FluidAudio splits the "them" channel into speakers (`them:spk1`…), click-to-name in the transcript; optional full-accuracy batch re-pass at meeting end. `schema_version` bump.

## M5 — Packaging

Hardened runtime, notarization, bundled CoreML models + FluidAudio `enforceOffline` (true 100%-offline out of box), updater decision, externalBin signing resolved for real (tauri#11992). Then private beta (~20 users, no instrumentation — interviews).

## M6 — Windows port

Bring capture + live transcript to Windows by replacing **only the sidecar**; the Rust core, Svelte UI, `sidecar-ipc-v1` protocol, and session-on-disk format stay unchanged. Full design: `docs/windows-port.md`.

- **New Rust sidecar** (`engine-windows/` → `minutiae-engine-x86_64-pc-windows-msvc.exe`) — Tauri's `externalBin` resolves the target-triple suffix, so no core/config change. Module layout mirrors Swift `EngineCore` (capture / asr / ipc / session / util) so the two platforms stay legible side by side.
- **Capture: WASAPI.** "Me" = shared-mode mic; "Them" = **per-process loopback** (`ActivateAudioInterfaceAsync` + `AUDIOCLIENT_ACTIVATION_PARAMS`, Win 10 build 20348+/Win 11) — the analog of the macOS process tap, behind the same `AudioCaptureSource` seam. Record native rate; resample only the ASR feed.
- **ASR: sherpa-onnx** (Rust crate, ONNX Runtime) running **Parakeet TDT** (the engine id `parakeet-tdt-v3`, macOS's default) with the Nemotron-3.5 streaming ids as the selectable alternates, keeping transcript parity with the CoreML engines on macOS. **DirectML** EP for NPU/iGPU accel (Neural Engine analog) with CPU fallback. Whisper variants rejected — the 30 s window fights the live-transcript + zero-hallucination targets.
- **Modularity rule:** platform-specific code (capture backend, ASR runtime) is quarantined to leaf modules behind `AudioCaptureSource` / `AsrEngine`; the RMS silence gate, IPC, session writing, and resampling stay shared. Optionally factor the wire types into a `minutiae-protocol` crate shared by core + Rust sidecar (Swift mirror stays hand-written).
- Same invariants apply: audio never crosses IPC, silence → zero segments (port the test), `schema_version` on JSON, offline-only, idle RAM < 250 MB, start < 1 s.

## Post-MLP (explicitly out for now)

Dictation surface (v0.2), Whisper/WhisperKit CJK fallback + Qwen3-ASR evaluation, mobile, sync, team spaces, cross-meeting RAG chat, integrations.
