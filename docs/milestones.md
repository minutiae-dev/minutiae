# Milestones

## M1 — Capture + live transcript (weeks 1–3) — IN PROGRESS

From `pnpm dev`: pick mic → start (<1 s) → live two-channel ("Me"/"Them") transcript with level meters during a real Zoom and Meet-in-Chrome call on AirPods → stop → session folder with valid `session.json`, `transcript.json`, two playable Opus/CAF files. Zero transcript text during silence. Sidecar crash mid-session leaves a readable partial transcript. Risk matrix (apps × audio routes × hot-switch/drift) has no red cells in the Zoom/Meet/AirPods rows.

Checkpoints:
- **A** — UI button → sidecar → UI event round-trip (IPC plumbing).
- **B (risk gate)** — record a Zoom call; both WAVs non-empty, clap-test cross-channel alignment ≤ 50 ms. If process taps fail → re-route to ScreenCaptureKit audio behind the same `SystemAudioTap` interface.
- **C** — YouTube in Safari while talking: correct channel attribution, zero segments during 60 s of silence, start < 1 s with TCC pre-granted.

## M2 — Scratchpad + enhancement

Scratchpad editor saved to `scratchpad.md`; enhancement pipeline (llama.cpp via `llama-cpp-2` crate or a second sidecar with bundled Qwen3-4B Q4, plus BYO OpenAI-compatible endpoint with model picker) merges scratchpad + transcript → Markdown + YAML frontmatter into the user-chosen vault folder. The session format is its input contract.

## M3 — Templates + calendar

Templates as Markdown files (frontmatter + prompt body) in a `templates/` dir, per-template model override. EventKit read-only (a `calendar` message family in the Swift sidecar) prefills `title`/`calendar_event` in `session.json`. Optional mic AEC (`setVoiceProcessingEnabled`) to cut echo bleed.

## M4 — Search + diarization refinement

`rusqlite` + FTS5 index over transcripts/notes — derived data, rebuildable, never authoritative (`sqlite-vec` later for semantic search). Pyannote-via-FluidAudio splits the "them" channel into speakers (`them:spk1`…), click-to-name in the transcript; optional full-accuracy batch re-pass at meeting end. `schema_version` bump.

## M5 — Packaging

Hardened runtime, notarization, bundled CoreML models + FluidAudio `enforceOffline` (true 100%-offline out of box), updater decision, externalBin signing resolved for real (tauri#11992). Then private beta (~20 users, no instrumentation — interviews).

## Post-MLP (explicitly out for now)

Dictation surface (v0.2), Whisper/WhisperKit CJK fallback + Qwen3-ASR evaluation, Windows port (same Rust core + protocol, sherpa-onnx/parakeet.cpp + WASAPI sidecar), mobile, sync, team spaces, cross-meeting RAG chat, integrations.
