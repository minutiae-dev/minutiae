# Contributing to Minutiae

Thanks for taking a look. This document covers how to get a development build
running, how the repository is laid out, what the tests cover, and the rules
that keep the product's promises intact.

## Setup

You need an Apple Silicon Mac on macOS 14.4 or later, Xcode 16.4+ (the engine
needs Swift 6, the MLX sidecar needs Swift 6.1), Rust stable with the
`aarch64-apple-darwin` target, Node 22 and pnpm 10.

```sh
git clone https://github.com/minutiae-app/minutiae.git
cd minutiae
pnpm install
pnpm dev
```

`pnpm dev` builds the Swift engine sidecar (`scripts/build-sidecar.sh`), starts
Vite, and runs `tauri dev`. The first launch downloads the ASR model (about
1.5 GB) into FluidAudio's cache.

The *Enhance* feature needs the MLX sidecar, which is deliberately not part of
`pnpm dev` because the Metal build is slow:

```sh
scripts/build-llm-sidecar.sh release   # once, and again after llm-engine/ changes
```

If `cargo` is not found when running through pnpm, put `~/.cargo/bin` on your
`PATH` first.

## Layout

| Path | What lives there |
|---|---|
| `app/src-tauri/` | Rust core: sidecar supervision (`sidecar.rs`), session state machine (`session.rs`), commands, events, settings, recents (`history.rs`), enhancement (`llm.rs`) |
| `app/src/` | Svelte 5 UI. State is one runes store, `lib/stores/session.svelte.ts`; IPC typings in `lib/ipc.ts` |
| `engine/` | Swift engine: `Capture/` (mic, process tap, resampling), `DSP/` (echo suppression), `ASR/` (FluidAudio engines, utterance segmentation), `Session/` (file writers, capture session), `IPC/` |
| `llm-engine/` | Swift MLX sidecar, a pure completion engine |
| `engine-windows/` | Rust sidecar for Windows, same wire protocol |
| `docs/` | Specs and design notes |
| `scripts/` | Build, sign, package |

`docs/architecture.md` explains the data flow and the invariants in detail.

## Tests

```sh
swift test --package-path engine                       # engine: DSP, segmentation, writers, IPC, shutdown
cargo test --manifest-path app/src-tauri/Cargo.toml    # core: protocol, session, history, settings, llm
cargo test --manifest-path engine-windows/Cargo.toml   # Windows sidecar, portable parts
pnpm --filter minutiae check                           # svelte-check over the UI
pnpm --filter minutiae test:ui                         # the UI in a real browser, against fixtures
```

The core's build script checks that the engine sidecar binary exists, so run
`pnpm sidecar:build` (or `pnpm dev`) once before `cargo test` on a fresh clone.

### The UI tests

`test:ui` runs Playwright (Chromium + WebKit) against `pnpm dev:ui-fixtures` — a
development-only Vite mode where `src/lib/transport.ts` swaps every Tauri
`invoke`, event listener and file dialog for the deterministic fixtures in
`src/lib/fixtures.ts`. Fixture mode requires *both* a dev build and
`--mode ui-fixtures`, so a production bundle cannot be talked into it. Add
`test:ui:headed` to watch it, or run `dev:ui-fixtures` and click around
yourself. Prefer accessible selectors (`getByRole`) over CSS.

There is no unit-test runner for the UI: a Svelte component that is worth
testing is worth testing through the app.

### The native smoke test

```sh
pnpm --filter minutiae build:native-test   # a separate app: `native-test` feature
pnpm --filter minutiae test:native         # WebdriverIO drives it
```

This one is the real Rust core — real commands, real session folders — with only
the two things a test must not touch replaced: the engine is a synthetic NDJSON
sidecar (`tests/native/sidecar.py`) and the data directory is a fresh temp dir
the build refuses to start without. So it catches what fixtures cannot (a
command that no longer exists, a session that never reaches disk) without ever
opening the microphone, downloading a model, or touching your meetings.
Microphone capture, TCC prompts and OAuth stay manual checks on a real Mac.

Heavier suites are opt-in through environment variables and skip otherwise:

```sh
# Resource benchmark: CPU per session-minute, footprint, disk, stop latency, ANE seconds
MINUTIAE_BENCH=1 MINUTIAE_BENCH_MINUTES=10 \
  swift test -c release --package-path engine --filter PipelineLoadTests

# End-to-end with the real ASR (needs speech files; `say` can make them)
say -o /tmp/far.aiff "..." && say -v Daniel -o /tmp/near.aiff "..."
MINUTIAE_E2E=1 MINUTIAE_E2E_SPEECH=/tmp/far.aiff MINUTIAE_E2E_NEAR=/tmp/near.aiff \
  swift test --package-path engine --filter EchoEndToEndTests
```

`SilenceSoakTests` and `ShutdownTests` run in the normal suite and are the
guards for two product promises: silence produces no transcript, and closing
the app never crashes the engine.

## Rules that keep the product honest

These are the promises the app makes to users. Changes that weaken them will
not be merged; `docs/architecture.md` explains the reasoning behind each.

1. Audio never crosses IPC. The engine writes audio to disk itself.
2. Plain files on disk are the source of truth. Any index is derived.
3. No telemetry. No network calls except model downloads.
4. Never force a sample format on an input tap; read the device's native
   format.
5. Recordings are aligned to session time: sample zero is session zero on both
   channels, with silence padded where a source delivered nothing.
6. The archive is mono, 16-bit, 16 kHz Opus, encoded during the session so
   stop is instant.
7. Silence produces zero transcript segments.
8. Transcription is segmented by utterance, not fixed windows; there is no
   overlap and no text de-duplication.
9. Audio captured before the models are ready is held, never dropped.
10. Echo suppression never damages the user's voice: below the confidence
    threshold the gain is exactly 1.0.
11. Never write to sidecar stdio with `FileHandle.write`; use `writeAll`.
12. Every persisted JSON document carries `schema_version`.

## Changing a wire protocol

The protocol docs are the source of truth and the implementations are
hand-mirrored. A change touches all of them in one PR:

- Engine protocol: `docs/protocol/sidecar-ipc-v1.md`,
  `app/src-tauri/src/protocol.rs`, `engine/Sources/EngineCore/IPC/Messages.swift`,
  and `engine-windows/src/ipc/messages.rs`.
- LLM protocol: `docs/protocol/llm-ipc-v1.md`, `app/src-tauri/src/llm_protocol.rs`,
  `llm-engine/Sources/minutiae-llm/IPC/Messages.swift`.

Both sides have round-trip tests; add a case for any new message.

## Pull requests

- Keep PRs focused. A refactor and a behaviour change are two PRs.
- Run the test commands above before opening a PR; CI runs the same.
- Describe what changed and why in the PR body. If you measured something
  (CPU, memory, ANE calls), include the numbers and how you got them; the
  table in `docs/architecture.md` says what to compare against.
- Sentence case in UI strings. The app explains rather than warns.
- No new dependencies without a note on why. FluidAudio is pinned exact
  because its API is still moving; bump it deliberately.

## About the `saas` feature

You will see `#[cfg(feature = "saas")]` and `VITE_SAAS` in the tree. They gate
a closed cloud-tier client that is not in this repository, so
`cargo build --features saas` does not build from a public checkout. Everything
else builds and runs without it, and the open-source app is complete on its
own.

## Reporting problems

Open an issue with your macOS version, Mac model, how audio was routed
(speakers, AirPods, wired headphones), and the app's log output
(`RUST_LOG=debug pnpm dev` prints it to the terminal). For security issues see
`SECURITY.md`.
