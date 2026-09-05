# Minutiae

Local-first meeting notepad for macOS. Minutiae captures your mic and the
other side of the call without a meeting bot, shows a live two-channel
transcript beside your notes, and, when the meeting ends, turns both into a
Markdown note in a folder you choose. Transcription and enhancement run on the
Mac in front of you. Nothing is sent anywhere.

> Requires an Apple Silicon Mac on macOS 14.4 or later.

## What it does

- **No bot joins the call.** System audio is captured with a Core Audio process
  tap and the mic with AVAudioEngine, so it works with Zoom, Meet, FaceTime or a
  YouTube tab alike.
- **Live transcript, two speakers.** Every line carries a *Me* / *Them* badge and
  a timestamp. On-device ASR (NVIDIA Parakeet TDT v3 via FluidAudio, on the
  Neural Engine) transcribes utterance by utterance as people speak.
- **Silence produces nothing.** An RMS gate runs before the model, so a pause is a
  pause, not a hallucinated sentence. There is a test for it.
- **Echo suppression.** On speakers the far end reaches the mic too; Minutiae
  uses the system-audio tap as a reference so it is not transcribed twice. It
  never clips your own voice.
- **Notes while you listen.** A scratchpad is saved with the session.
- **Enhance, on-device.** A local language model (Qwen3.5-4B via MLX, one
  2.9 GB download) merges transcript and notes into a finished note with YAML
  frontmatter.
- **Plain files.** Sessions are JSON, Opus audio and Markdown on disk. Notes land
  in any folder, so an Obsidian vault opens them as-is.
- **Small.** Idle footprint under 250 MB, capture starts in under a second, no
  telemetry, no network calls except model downloads.

## Install

1. Download the latest `Minutiae.dmg` from
   [Releases](https://github.com/minutiae-app/minutiae/releases/latest) and
   drag Minutiae to Applications.
2. On first launch macOS asks for microphone and system-audio recording
   permission. Both are required to capture a call.
3. The app downloads the ASR model (about 1.5 GB, once) and compiles it for the
   Neural Engine. Recording is available as soon as that finishes.
4. Pick a notes folder in the sidebar (*Vault*). The language model for
   *Enhance* is downloaded only when you first ask for it.

Sessions live in `~/Library/Application Support/Minutiae/sessions/`; the format
is documented in [`docs/session-format.md`](docs/session-format.md).

## Build from source

Requirements: Apple Silicon, macOS 14.4+, Xcode 16.4+ (Swift 6.1), Rust stable,
Node 22, pnpm 10.

```sh
pnpm install
pnpm dev                      # builds the Swift engine sidecar, then runs `tauri dev`

# Optional, for the Enhance feature in a dev build (slow MLX build, run once):
scripts/build-llm-sidecar.sh release
```

Tests:

```sh
swift test --package-path engine                       # audio engine
cargo test --manifest-path app/src-tauri/Cargo.toml    # Rust core
cargo test --manifest-path engine-windows/Cargo.toml   # Windows sidecar (portable parts)
pnpm --filter minutiae check                           # svelte-check
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development workflow and
[`docs/signed-build.md`](docs/signed-build.md) for producing a signed,
notarized release.

## How it is put together

```
┌──────────────────────────────┐   NDJSON over stdio   ┌──────────────────────────────┐
│ Tauri 2 app                  │ ◄───────────────────► │ minutiae-engine  (Swift)     │
│ Rust core + Svelte 5 UI      │ sidecar-ipc-v1        │ process tap + mic capture    │
│ sessions, settings, recents, │                       │ echo suppression             │
│ prompt assembly, vault notes │                       │ FluidAudio ASR on the ANE    │
│                              │   NDJSON over stdio   ├──────────────────────────────┤
│                              │ ◄───────────────────► │ minutiae-llm  (Swift, MLX)   │
│                              │ llm-ipc-v1            │ Qwen3.5-4B completion engine │
└──────────────────────────────┘                       └──────────────────────────────┘
```

Audio never crosses the process boundary: the engine writes the audio files
itself and only control messages and transcript events travel over stdio.
[`docs/architecture.md`](docs/architecture.md) walks through a session end to
end and lists the invariants the design depends on.

| Directory | Contents |
|---|---|
| `app/` | Tauri 2 application: Rust core (`app/src-tauri`) and Svelte 5 UI (`app/src`) |
| `engine/` | Swift audio and ASR sidecar (SwiftPM package) |
| `llm-engine/` | Swift MLX sidecar for on-device enhancement |
| `engine-windows/` | Rust sidecar for the Windows port (phase 1: IPC and device enumeration) |
| `docs/` | Protocol specs, session format, architecture, milestones, signed builds |
| `scripts/` | Build, packaging, signing and icon scripts |

## Docs

- [`docs/architecture.md`](docs/architecture.md), how the pieces fit and why
- [`docs/protocol/sidecar-ipc-v1.md`](docs/protocol/sidecar-ipc-v1.md), the engine wire protocol
- [`docs/protocol/llm-ipc-v1.md`](docs/protocol/llm-ipc-v1.md), the LLM sidecar wire protocol
- [`docs/session-format.md`](docs/session-format.md), what a session folder contains
- [`docs/milestones.md`](docs/milestones.md), where the project is and where it is going
- [`docs/windows-port.md`](docs/windows-port.md), the Windows design

## Open core

The public build has no account, no sync and no cloud. A separate, closed
cloud tier (sync of session text and cloud enrichment) exists as a client
module that is not in this repository; the `saas` Cargo feature and the
`VITE_SAAS` build flag are the hooks it plugs into. Without that module the
feature does not build, and the code you see here is the whole product for
everyone else.

## Status

Milestones 1 and 2 (capture, live transcript, scratchpad, on-device enhance)
are shipped. Signed and notarized builds are scripted. The Windows sidecar has
its IPC seam in place but no capture yet. See
[`docs/milestones.md`](docs/milestones.md).

## License

MIT. See [`LICENSE`](LICENSE). Models downloaded at runtime and third-party
libraries have their own licenses; see [`THIRD_PARTY.md`](THIRD_PARTY.md).
