# Minutiae — agent notes

Human-facing docs: `README.md`, `CONTRIBUTING.md`, `docs/architecture.md`. This file is the terse version for agents and must stay consistent with them.

Local-first macOS meeting notepad. Tauri 2 (Rust core + Svelte 5) with a Swift sidecar (`engine/`) that owns audio capture and on-device ASR (FluidAudio / Parakeet TDT v3 on the Neural Engine).

## Invariants — do not violate

- **Audio never crosses IPC.** The Swift sidecar writes audio files itself; only control messages and transcript events go over stdio (NDJSON, spec: `docs/protocol/sidecar-ipc-v1.md`). The protocol doc is the source of truth; `app/src-tauri/src/protocol.rs` and `engine/Sources/EngineCore/IPC/Messages.swift` are hand-mirrored from it — change all three together.
- **Plain files are authoritative.** `.md` and session JSON on disk are the source of truth; any index (SQLite later) is derived and rebuildable.
- **No telemetry, no network calls** except model downloads (FluidAudio from HuggingFace) and user-configured BYO LLM endpoints (M2+).
- **Never force a format on audio input taps** — AirPods mics deliver 16/24 kHz. This is a *capture* rule: read the device's native format, never demand one. Persistence is a separate decision — the archive is deliberately mono/16-bit/16 kHz (see below).
- **Recordings are session-time aligned.** Sample 0 of every audio file is
  session time zero: `AudioFileWriter.write(_:at:)` pads silence for any stretch
  its source did not deliver (the tap's IOProc does not run while the output
  device is idle, so `them` routinely starts late), and `finalize(at:)` pads the
  tail. Both channels therefore span the session and a transcript timestamp
  indexes the audio directly. `EchoAnalyzer` and `WindowedTranscriber` handle the
  same holes by re-anchoring their own clocks — never by ignoring them.
- **The archive is mono, 16-bit, 16 kHz Opus, and stop is O(1).** Both channels persist at the rate the ASR consumes, so re-transcribing a recording feeds the model exactly what it saw live; the encode cap never *upsamples* (a 16 kHz mic stays 16 kHz). Opus is encoded incrementally on a background queue during the session, with the mono 16-bit `.part.wav` as the crash-safe copy — Opus-in-CAF is not recoverable from a truncated file. Never move the encode back to `finalize()`: a one-hour session took ~40 s to transcode at stop, and now takes ~0.1 s.
- **Silence must produce zero transcript segments** (RMS gate before ASR). This is a marketed differentiator; there is a test for it. The gate runs *in place* on the ring buffer, so silence costs one vDSP pass and a pointer bump — never a copy, never an ANE call. `MINUTIAE_ASR_TRIM=0` disables the extra (now defensive) leading/trailing trim inside an accepted utterance.
- **Transcription is segmented by UTTERANCE, not by fixed window.** Parakeet's
  CoreML encoder consumes a fixed 15 s block whatever you feed it, so an ANE call
  costs the same for 2 s of audio as for 10 s — the unit to minimize is calls,
  not seconds. `WindowedTranscriber` cuts where the speaker pauses (0.7 s of
  quiet), caps an utterance at 10 s, and carries `TdtDecoderState` across cuts
  for language-model continuity. There is no window overlap and therefore no
  text de-dup; do not reintroduce either.
- **Audio captured before the models finish loading is HELD, never dropped.**
  The ring keeps it and the pump refuses to pop a window the engine cannot
  transcribe; `CaptureSession` calls `engineBecameReady()` when `prepare()`
  returns. The old code popped the window first and lost it to a
  `notInitialized` throw — on the cached-model path the core never sends
  `prepare_models`, so this was every session's opening seconds.
- **Echo suppression must never damage the user's voice.** On speakers the far end reaches the mic acoustically *and* the tap electronically, so it would be transcribed on both channels. `EngineCore/DSP/EchoAnalyzer.swift` suppresses it using the `them` tap as reference. Two hard rules: below the correlation-confidence threshold (headphones — no acoustic path) the gain is *exactly* 1.0, bit-identical passthrough; and double-talk raises the floor and un-suppresses instantly. The acceptable failure is leaked echo, never clipped near-end speech.
- **Never write to sidecar stdio with `FileHandle.write`.** It raises an ObjC `NSFileHandleOperationException` on EPIPE, which Swift cannot catch — the engine aborts with SIGABRT instead of shutting down, losing the un-finalized session and surfacing an ordinary app quit as a crash. Use `writeAll` (`EngineCore/Util/Log.swift`), which loops on POSIX `write(2)` and treats a closed pipe as a no-op. `ShutdownTests` guards this against the real binary.
- All persisted JSON carries `schema_version`.

## Non-functional targets (these are the product)

Idle RAM < 250 MB · capture start < 1 s · 100% offline path · no hallucinated text during pauses.

## Build/test

```sh
pnpm dev                                            # sidecar build + tauri dev
swift test --package-path engine
cargo test --manifest-path app/src-tauri/Cargo.toml
scripts/build-sidecar.sh [release]                  # → app/src-tauri/binaries/minutiae-engine-aarch64-apple-darwin

# UI, in a real browser against fixtures (Chromium + WebKit). `dev:ui-fixtures`
# is a dev-only Vite mode where `src/lib/transport.ts` swaps invoke/listen/dialog
# for `src/lib/fixtures.ts`; a production bundle cannot enable it.
pnpm --filter minutiae test:ui                      # add :headed to watch it
pnpm --filter minutiae dev:ui-fixtures              # click around yourself

# The real Rust core through WebDriver: real commands, real session folders,
# synthetic NDJSON sidecar, temp data dir the build refuses to start without.
pnpm --filter minutiae build:native-test && pnpm --filter minutiae test:native

# Resource benchmark (opt-in): CPU/s per session-minute, footprint growth,
# bytes on disk, stop latency and ANE seconds, for a synthetic session driven
# ~150x realtime through the real pipeline with a stub ASR.
MINUTIAE_BENCH=1 MINUTIAE_BENCH_MINUTES=10 \
  swift test -c release --package-path engine --filter PipelineLoadTests
```

`SilenceSoakTests` runs in the normal suite and is the long-silence guard:
timestamps after a five-minute break, zero ASR calls across ten silent minutes,
flat footprint, a delay line that does not accumulate, and bit-identical mic
passthrough when `them` never delivers. `PipelineHarness.swift` mirrors
`CaptureSession.handle(buffer:hostTime:channel:)` — keep the two in sync or the
benchmark stops measuring the shipping path.

Benchmarks push audio far faster than realtime, so they call
`AudioFileWriter.waitForEncoder()` periodically; without that the background
Opus encoder falls behind, trips its 30 s backlog guard, and you end up timing
the fallback transcode instead of the incremental path.

Sidecar is pure SPM (no .xcodeproj). Info.plist is embedded into the binary via `-sectcreate` linker flags in `Package.swift` (needed for TCC usage strings); the build script ad-hoc codesigns with the audio-input entitlement.

## Where the resources go

Measured on a 10-minute synthetic session (real pipeline, stub ASR), mixed
20 s speech / 40 s silence, per hour of session audio. Re-measure with
`PipelineLoadTests` before claiming a regression — and re-measure on an idle
machine: a busy one inflates the CPU column by half a point.

| | scratch WAV | archive | pipeline CPU | stop → finalized (1 h) | ANE audio | ANE calls |
|---|---|---|---|---|---|---|
| M1 (5 s windows) | 1.93 GB/h | ~42 MB/h | 1.39 % of a core | ~30 s | 630 s | ~756/h |
| windowed Nemotron | 0.66 GB/h | ~13 MB/h | 1.45 % of a core | ~0.3 s | 522 s | ~624/h |
| now (Parakeet utterances) | 0.66 GB/h | ~13 MB/h | 1.69 % of a core | ~0.5 s | 402 s | 300/h |

CPU is deliberately reported as one number: the Opus encoder runs on a
background queue *during* the session and `getrusage` counts every thread, so
there is no honest capture-only figure to quote. The quarter-point rise is the
segmenter waking on every 100 ms block instead of every 5 s window; it buys the
ANE column, which is the one that matters. Archive figures include the fixed
per-file CAF header — see Gotchas.

Sidecar footprint with the models loaded and idle: **25 MB** (57 MB RSS),
against a 250 MB target. Disk writes dominate the capture path — `pwrite` was
the single largest entry in a `sample` profile — so bytes written is the first
thing to look at, not arithmetic.

**The ANE is the real consumer once ASR is live, and it bills per call.**
Parakeet's CoreML encoder takes a fixed 240 000-sample (15 s) block whatever you
hand it, so a 2 s window costs the same as a 10 s one. Utterance segmentation
therefore cut ANE calls roughly in half (624 → 300 per hour) on meeting-like
input, on top of removing the 25 % overlap the 5 s / 4 s geometry paid forever.
What is left on the table is the calls themselves: batching the two channels'
utterances into one encoder block when both are short, or a smaller model for
the `me` channel, are the next real wins. Do not go back to fixed windows.

## Gotchas

- Core Audio process taps require macOS 14.4+ and the `NSAudioCaptureUsageDescription` TCC prompt. In dev, TCC attribution may roll up to the terminal; fallback is granting permission to the sidecar standalone via `swift run`.
- Apple's Opus encoder only muxes into CAF (not Ogg); session metadata records `container: "caf"`. It also prepends a **fixed ~236 KB header** to every CAF regardless of duration (measured identical at 25 s and 1 h, and independent of write chunk size — it is not an artifact of the incremental encoder). Budget it when reasoning about small files: a 25 s clip is 280 KB of which 14 kbps × 25 s = 45 KB is audio.
- FluidAudio is pinned `.exact` in `engine/Package.swift` — 0.x API churn; bump deliberately.
- Driving the sidecar headlessly (piping NDJSON to the binary) **hangs on `start_session`** when the mic TCC grant is undetermined: `MicCapture.ensureMicPermission()` blocks on a semaphore waiting for a prompt that can never appear. Test capture through the app, or grant the sidecar permission standalone first.
- Echo suppression: `MINUTIAE_ECHO_SUPPRESS=0` disables it (fully bypasses the delay line), `MINUTIAE_KEEP_RAW_ME=1` also writes the unprocessed `audio-me-raw`, `MINUTIAE_ECHO_DEBUG=1` traces every delay estimate. It needs ~2 s of far-end audio to lock the delay, so the opening seconds of a session are not suppressed. The heavy end-to-end tests (real ASR) are opt-in:
  ```sh
  say -o /tmp/far.aiff "..." && say -v Daniel -o /tmp/near.aiff "..."
  MINUTIAE_E2E=1 MINUTIAE_E2E_SPEECH=/tmp/far.aiff MINUTIAE_E2E_NEAR=/tmp/near.aiff \
    swift test --package-path engine --filter EchoEndToEndTests
  ```
