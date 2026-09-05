# Architecture

Minutiae is three processes on the user's Mac, joined by newline-delimited JSON
over stdio. Nothing else talks to anything.

```
Svelte 5 UI (webview) ──invoke / events──  Rust core (Tauri 2, minutiae_lib)
                                             ├── stdin/stdout ──▶ minutiae-engine   Swift, engine/
                                             └── stdin/stdout ──▶ minutiae-llm      Swift + MLX, llm-engine/
```

- **Rust core** (`app/src-tauri/src/`) owns policy: session lifecycle and files,
  settings, recents, prompt assembly, vault notes, and supervision of both
  sidecars (spawn, handshake, pings, respawn with backoff).
- **Engine sidecar** (`engine/`) owns audio: capture, echo suppression,
  utterance segmentation, on-device ASR, and writing the audio files.
- **LLM sidecar** (`llm-engine/`) is a pure completion engine: prompt in,
  tokens out. It is spawned lazily on the first *Enhance* and loads the model
  on demand to protect the idle-memory target.
- **UI** (`app/src/`) is a single runes store (`lib/stores/session.svelte.ts`)
  fed by Tauri events; components render it.

The wire protocols are specified in `docs/protocol/sidecar-ipc-v1.md` and
`docs/protocol/llm-ipc-v1.md`. The Rust and Swift message types are
hand-mirrored from those documents; the docs win when they disagree.

## A session, end to end

1. **Record.** `CaptureControls.svelte` calls `session.start()` in the store,
   which invokes the `start_session` command (`commands.rs`).
2. **Folder first.** `SidecarManager::start_session` (`sidecar.rs`) creates
   `~/Library/Application Support/Minutiae/sessions/<started-at>--<ULID>/` and
   moves the `SessionMachine` (`session.rs`) to *starting* before anything is
   sent, so a crash from here on still leaves a folder to recover.
3. **Request.** A `start_session` message with the session id, directory, mic
   device and engine id goes down the engine's stdin. The core correlates the
   reply by `id`; pings continue every 5 s and two missed pongs kill and respawn
   the engine.
4. **Capture.** `CaptureSession.swift` starts the mic (`MicCapture`, native
   format, never forced) and the *them* source (`SystemAudioTap`, a Core Audio
   process tap, or a named input device). One `SessionClock` stamps both
   channels from the same host-time anchor.
5. **Per buffer.** `handle(buffer:hostTime:channel:)` converts host time to
   session seconds, meters the level, writes the audio to disk through
   `AudioFileWriter` (a crash-safe PCM `.part.wav` plus incremental Opus in
   CAF on a background queue), and pushes a 16 kHz mono copy into the channel's
   `RingBuffer` for ASR. On speakers, the *me* path goes through
   `DelayedMicPipeline`, which applies the gain `EchoAnalyzer` derives from the
   *them* tap.
6. **Segment.** `WindowedTranscriber` cuts where the speaker pauses (0.7 s),
   caps an utterance at 10 s, gates on RMS so silence never reaches the model,
   and carries decoder state across cuts. Utterances are transcribed one at a
   time on the shared FluidAudio engine (`TranscribeQueue`) on the Neural
   Engine.
7. **Event.** Each result is sent up stdout as a `transcript` message. The
   core appends final segments to `transcript.json` (flushed every 20 segments
   or 10 s) and emits `transcript:segment` to the UI. Levels flow the same way
   at 10 Hz.
8. **Stop.** `stop_session` drains the Opus encoder, closes the CAFs, deletes
   the `.part.wav` files, and replies with the audio manifest. The core writes
   `session.json`, and drops a plain transcript note into the vault so an
   unenhanced meeting is still readable.
9. **Enhance.** `enhance_session` reads `transcript.json` and `scratchpad.md`,
   builds the prompt in `llm.rs`, streams tokens from `minutiae-llm` to the UI,
   and writes `<Title>.md` with YAML frontmatter into the vault.

## On disk

| Path | Contents |
|---|---|
| `~/Library/Application Support/Minutiae/settings.json` | vault folder, thinking mode, ASR engine (`schema_version: 1`) |
| `…/Minutiae/sessions/<YYYY-MM-DDTHH-MM-SSZ>--<ULID>/session.json` | metadata written at stop; a stub is back-filled for crashed sessions |
| `…/transcript.json` | final segments only, flushed incrementally |
| `…/audio-me.caf`, `…/audio-them.caf` | mono, 16-bit, 16 kHz Opus in CAF, both starting at session time zero |
| `…/audio-*.part.wav` | transient crash-safe PCM, removed on a clean stop |
| `…/scratchpad.md` | your notes |
| `<vault>/<Title>.md` | transcript note, replaced by the enhanced note |

`docs/session-format.md` is the full specification. Files are the source of
truth; any index built over them is derived and rebuildable.

## Invariants

The design depends on these. Each has a reason, and most have a test.

- **Audio never crosses IPC.** The engine writes the files. Only control
  messages and transcript events travel over stdio.
- **Plain files are authoritative.** Markdown and JSON on disk are the truth.
- **No telemetry, no network calls** except model downloads from Hugging Face.
- **Never force a format on an input tap.** AirPods deliver 16 or 24 kHz;
  read the native format and resample only the ASR feed.
- **Recordings are session-time aligned.** Sample zero of every audio file is
  session time zero. `AudioFileWriter.write(_:at:)` pads silence for stretches
  a source did not deliver (the tap's IOProc idles while the output device is
  idle) and `finalize(at:)` pads the tail, so a transcript timestamp indexes
  the audio directly.
- **The archive is mono, 16-bit, 16 kHz Opus, and stop is O(1).** Both
  channels persist at the rate the ASR consumes, so re-transcribing feeds the
  model exactly what it saw live. Opus is encoded incrementally during the
  session; the PCM `.part.wav` is the crash-safe copy. A one-hour session took
  about 40 s to transcode at stop before this and takes about 0.1 s now.
- **Silence produces zero transcript segments.** The RMS gate runs in place on
  the ring buffer before any ASR call, so silence costs one vDSP pass and a
  pointer bump. `SilenceSoakTests` guards ten silent minutes with zero ASR
  calls and a flat footprint.
- **Transcription is segmented by utterance, not fixed window.** Parakeet's
  CoreML encoder consumes a fixed 15 s block whatever it is given, so the unit
  to minimise is calls, not seconds. There is no window overlap and therefore
  no text de-duplication.
- **Audio captured before the models are ready is held, never dropped.** The
  ring keeps it and the pump refuses to pop a window the engine cannot
  transcribe; `CaptureSession` calls `engineBecameReady()` when `prepare()`
  returns.
- **Echo suppression never damages the user's voice.** Below the correlation
  confidence threshold (headphones, no acoustic path) the gain is exactly 1.0,
  bit-identical passthrough; double-talk raises the floor and un-suppresses
  instantly. The acceptable failure is leaked echo, never clipped speech.
- **Never write to sidecar stdio with `FileHandle.write`.** It raises an
  Objective-C exception on EPIPE that Swift cannot catch, and the engine
  aborts instead of shutting down. `writeAll` (`Util/Log.swift`) loops on
  `write(2)` and treats a closed pipe as a no-op. `ShutdownTests` checks the
  real binary.
- **All persisted JSON carries `schema_version`.**

## Targets and measurements

Idle RAM under 250 MB, capture start under 1 s, a fully offline path, and no
hallucinated text during pauses. Measured on a ten-minute synthetic session
through the real pipeline with a stub ASR (mixed 20 s speech / 40 s silence),
per hour of session audio:

| | scratch WAV | archive | pipeline CPU | stop → finalized (1 h) | ANE audio | ANE calls |
|---|---|---|---|---|---|---|
| M1 (5 s windows) | 1.93 GB/h | ~42 MB/h | 1.39 % of a core | ~30 s | 630 s | ~756/h |
| windowed Nemotron | 0.66 GB/h | ~13 MB/h | 1.45 % of a core | ~0.3 s | 522 s | ~624/h |
| now (Parakeet utterances) | 0.66 GB/h | ~13 MB/h | 1.69 % of a core | ~0.5 s | 402 s | 300/h |

Sidecar footprint with the models loaded and idle is about 25 MB (57 MB RSS).
Disk writes dominate the capture path, and the Neural Engine bills per call,
which is why utterance segmentation mattered more than any arithmetic. Re-run
`PipelineLoadTests` (see `CONTRIBUTING.md`) on an idle machine before claiming a
regression.

## Environment variables

All are read by the engine or its tests; the core and UI read none.

| Variable | Effect |
|---|---|
| `MINUTIAE_ECHO_SUPPRESS=0` | Disable echo suppression entirely (no delay line) |
| `MINUTIAE_KEEP_RAW_ME=1` | Also write the unprocessed mic capture as `audio-me-raw` |
| `MINUTIAE_ECHO_DEBUG=1` | Trace every delay estimate to stderr |
| `MINUTIAE_ASR_TRIM=0` | Disable the defensive leading/trailing trim inside an accepted utterance |
| `MINUTIAE_BENCH=1`, `MINUTIAE_BENCH_MINUTES=n` | Opt into the resource benchmark |
| `MINUTIAE_E2E=1`, `MINUTIAE_E2E_SPEECH`, `MINUTIAE_E2E_NEAR` | Opt into the real-ASR end-to-end tests |

Other knobs: `RUST_LOG` for the core (default `info,minutiae_lib=debug`),
`HF_HOME` for where the language model is cached, and the signing variables
described in `docs/signed-build.md`.

## Platform notes

- Core Audio process taps need macOS 14.4+ and the
  `NSAudioCaptureUsageDescription` prompt. The usage strings are embedded into
  the bare sidecar binary with `-sectcreate` because TCC reads them from the
  process, not the app bundle.
- Apple's Opus encoder only muxes into CAF, and prepends a fixed header of
  about 236 KB to every file regardless of duration.
- Driving the engine headlessly (piping NDJSON) hangs on `start_session` until
  the mic permission has been granted once; test capture through the app.
- FluidAudio is pinned exact in `engine/Package.swift`.
- The Windows port replaces only the engine sidecar; see `docs/windows-port.md`.
