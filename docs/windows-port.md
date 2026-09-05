# Windows port — design

Status: **proposed** (no code yet). Targets the M-series "Windows port" milestone in `milestones.md`.

Minutiae's macOS build is a Tauri app (Rust core + Svelte) driving a **Swift sidecar** (`engine/`) that owns audio capture and on-device ASR. The Windows port keeps the Rust core, the Svelte UI, and the `sidecar-ipc-v1` wire protocol **unchanged**, and replaces only the sidecar with a native Windows implementation.

## Strategy: one protocol, two sidecars

The process boundary is already the platform seam. The core spawns a binary named `minutiae-engine` via `tauri-plugin-shell`; Tauri resolves the platform suffix automatically:

- macOS → `binaries/minutiae-engine-aarch64-apple-darwin` (Swift, existing)
- Windows → `binaries/minutiae-engine-x86_64-pc-windows-msvc.exe` (Rust, new)

Both speak the **same NDJSON protocol** (`docs/protocol/sidecar-ipc-v1.md`). As long as the Windows sidecar honors the envelope, handshake, and message families, the core, the UI, and the session-on-disk format are untouched. This is the modularity guarantee: **platforms are swapped at the binary boundary, not with `#[cfg]` forests in shared code.**

### Why Rust (not Swift) for the Windows sidecar

Swift-on-Windows is immature and, more decisively, the macOS sidecar's ASR stack (FluidAudio / Parakeet-CoreML / Neural Engine) is Apple-only — none of it ports. The Windows sidecar is a from-scratch process regardless of language. Rust wins because:

- The best Windows ASR runtime (sherpa-onnx) ships a maintained **Rust crate** with Windows prebuilts.
- WASAPI is reachable via the `windows` crate (official Microsoft bindings).
- The wire types can be **shared as a Rust crate** with the core (see below), eliminating one hand-mirror.

## Component choices

| Concern | macOS (today) | Windows (this doc) |
|---|---|---|
| "Me" capture | Core Audio mic tap | **WASAPI** shared-mode capture |
| "Them" capture | Core Audio **process tap** | **WASAPI per-process loopback** (`ActivateAudioInterfaceAsync` + `AUDIOCLIENT_ACTIVATION_PARAMS`, Win 10 build 20348+/Win 11) |
| ASR runtime | FluidAudio (CoreML, ANE) | **sherpa-onnx** (ONNX Runtime) Rust crate |
| ASR model | Nemotron-3.5 streaming (CoreML) | **Nemotron-3.5 streaming** (ONNX) — same model family, keeps transcript parity |
| Accel | Neural Engine | ONNX Runtime EP: **DirectML** (Copilot+ NPU / iGPU / GPU) → CPU fallback |
| Audio encode | Opus → CAF | Opus → Ogg/`.opus` (no Apple CAF quirk; `container` recorded in session metadata) |

### ASR: sherpa-onnx + streaming Nemotron-3.5

- macOS defaults to **batch Parakeet TDT 0.6B v3** (multilingual, auto-detect, natively punctuated) — engine id `parakeet-tdt-v3` — with the two Nemotron-3.5 streaming variants (`nemotron-streaming-ml` / `nemotron-streaming-en`) still selectable from the hidden model picker. Windows must reach transcript parity with the same model family; sherpa-onnx has ONNX paths for both.
- sherpa-onnx is chosen over parakeet.cpp (Mac/Linux only today) and whisper.cpp/faster-whisper (Whisper's fixed 30 s window fights our sub-second live-transcript and zero-hallucination-during-pauses targets). sherpa-onnx upstream already ships **Nemotron-3.5 streaming** support — the English transducer first, with the multilingual (`prompt_index`) variant landing more recently — so both selectable models have an ONNX path.
- Run the same chunk tier as macOS (FluidAudio's 2240 ms default) so the live-transcript UX matches; the cache-aware encoder keeps latency low without re-running overlapping context.
- ONNX Runtime's **DirectML** execution provider gives the Windows analog to the Neural Engine — NPU/iGPU acceleration to protect the idle-RAM and battery targets — with automatic CPU fallback on machines without it.
- The Phase-1 stub already advertises the `nemotron-streaming-ml` engine id (`engine-windows/src/asr/stub.rs`); Phase 2 swaps in the real sherpa-onnx backend behind the same `AsrEngine` trait, mapping the wire engine id to the matching ONNX model.

## Internal module layout (keep platforms independently buildable)

The Windows sidecar mirrors the Swift `EngineCore` module breakdown so the two stay legible side by side. Proposed crate at repo root, sibling to `engine/`:

```
engine-windows/                 # standalone Cargo crate → minutiae-engine.exe
  src/
    main.rs                     # wire stdio, run controller loop
    ipc/        transport.rs    # NDJSON over stdin/stdout (mirrors StdioTransport.swift)
    capture/    mic.rs          # WASAPI shared-mode mic  ── "Me"
                loopback.rs     # WASAPI per-process loopback ── "Them"
                resampler.rs    # native-rate in, resample ONLY the ASR feed
                ring_buffer.rs
    asr/        engine.rs       # AsrEngine trait + SherpaAsrEngine impl
                windowed.rs     # chunked/streaming transcriber
                rms_gate.rs     # silence → zero segments (shared invariant)
    session/    writer.rs       # Opus encode + file writing (audio never crosses IPC)
                capture.rs      # orchestrates capture + ASR + session lifecycle
    util/       log.rs  clock.rs
```

Two platform-abstraction seams keep platform-specific code quarantined to leaf modules; everything above them is portable logic:

- **`AudioCaptureSource`** — `mic.rs` / `loopback.rs` implement it on Windows; `SystemAudioTap` / `MicCapture` are the macOS analogs. (macOS already abstracts this — see the `SystemAudioTap` fallback note in `milestones.md` M1 checkpoint B.)
- **`AsrEngine`** — already a protocol in `engine/Sources/EngineCore/ASR/AsrEngine.swift`; the Rust crate defines the same trait with `SherpaAsrEngine` behind it.

### Shared vs platform-specific

- **Shared, must not fork per platform:** the protocol contract, the session-on-disk format, the RMS silence gate semantics, "audio never crosses IPC", native-rate recording / resample-only-the-ASR-feed, `schema_version` on persisted JSON.
- **Platform-specific, isolated to leaf modules:** the capture backend and the ASR runtime/model packaging. Nothing else.

### Optional: share the wire types as a crate

Both the core (`app/src-tauri/src/protocol.rs`) and the new Rust sidecar are Rust. Factoring the envelope + message structs into a small `minutiae-protocol` crate consumed by both removes one of the three hand-mirrors. **The Swift mirror stays hand-written** — so the protocol doc remains the source of truth and the "change all three together" rule still holds (it just becomes "change the doc, the shared crate, and Messages.swift").

## Build & packaging (separate per platform)

- No cross-compilation. macOS builds on macOS (`scripts/build-sidecar.sh`), Windows builds on Windows (`scripts/build-sidecar.ps1`, new). Each emits its own target-triple-suffixed binary into `binaries/`; `pnpm tauri build` on each host bundles the matching one.
- `tauri.conf.json` `externalBin: ["binaries/minutiae-engine"]` already resolves per target — no edit needed.
- sherpa-onnx's ONNX Runtime + model files are extra payload: place the `onnxruntime.dll` / DirectML provider next to the `.exe`, and resolve model files from an app-data cache (downloaded on first run, same as macOS). Signing/packaging detail belongs in the Packaging milestone.

## Invariant checklist (must survive the port)

- [ ] Audio never crosses IPC — the Rust sidecar writes Opus files itself; only control + transcript NDJSON on stdio.
- [ ] Silence → zero transcript segments — RMS gate before the ASR feed, with the existing test ported.
- [ ] Never force a format on input taps — record native rate; resample only the ASR feed.
- [ ] All persisted JSON carries `schema_version`.
- [ ] No telemetry / no network except model downloads.
- [ ] Idle RAM < 250 MB · capture start < 1 s · 100% offline path.

## Open questions

- Per-process loopback requires Win 10 21H2+ — set that as the floor, or add an all-system-audio fallback (less precise "them" attribution) for older builds?
- Which streaming Parakeet checkpoint balances WER vs latency vs size best on a CPU-only laptop — bench `unified-en-0.6b` vs the 120 m EOU model before committing.
- Diarization parity (M4 `them:spk1` sub-labels): sherpa-onnx has speaker models, but confirm the streaming-path story.
