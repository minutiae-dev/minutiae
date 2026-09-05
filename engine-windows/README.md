# minutiae-engine (Windows sidecar)

The Windows audio/ASR sidecar — a protocol twin of the macOS Swift engine
(`../engine/`). It speaks the same NDJSON `sidecar-ipc-v1` protocol over stdio,
so the Rust core (`../app/src-tauri`) spawns it unchanged. Design rationale and
the build/packaging story live in `../docs/windows-port.md` (milestone **M6**).

## Status: Phase 1 — IPC seam ✅

Implemented and verified:

- `ipc/` — NDJSON transport + the hand-mirrored wire messages (twin of
  `app/src-tauri/src/protocol.rs`; round-trip tests assert byte-shape parity).
- `controller.rs` — the dispatch loop. Pings are answered **on the reader
  thread** so liveness holds regardless of work backlog (the core kills the
  process after 2 missed pongs); everything else is queued to a serial worker.
- `capture/devices.rs` — WASAPI input-device enumeration (`#[cfg(windows)]`),
  with a mock on non-Windows hosts.
- `util/` — `SessionClock` (wall-clock + monotonic anchor) and stderr logging.
- `asr/` — the `AsrEngine` seam + a `StubAsrEngine` (reports models ready).

`start_session` currently fails fast with a non-fatal error — capture is Phase 2.

## Not yet (Phase 2): capture + ASR + session

WASAPI mic + per-process loopback, `rubato` resampling, the windowed
transcriber (5 s / 4 s hop, **−50 dBFS RMS gate** → silence yields zero
segments), the sherpa-onnx Parakeet backend, and WAV→Ogg/Opus session writing.

## Build & test

```sh
# Portable core builds & tests on any host (macOS dev box included):
cargo test --manifest-path engine-windows/Cargo.toml

# Full Windows build (produces the Tauri-discoverable triple-named binary):
pwsh scripts/build-sidecar.ps1 [debug|release]
#   → app/src-tauri/binaries/minutiae-engine-<host-triple>.exe
```

> **Windows-host caveat:** the WASAPI code in `capture/devices.rs` is gated
> behind `#[cfg(windows)]` and is **not exercised by the macOS dev build**. It
> compiles only on a Windows target; verify with
> `cargo build --target x86_64-pc-windows-msvc` on a Windows machine. The rest
> of the crate (ipc/controller/util/asr) is portable and covered by `cargo test`.

## Manual handshake smoke test

```sh
printf '%s\n' \
  '{"v":1,"type":"hello","id":"h1"}' \
  '{"v":1,"type":"list_devices","id":"d1"}' \
  '{"v":1,"type":"ping","id":"pg1"}' \
  '{"v":1,"type":"shutdown"}' \
  | ./target/debug/minutiae-engine
```

Expect a `pong`, a `hello_ack` (with `engine_versions`/`models_ready`), a
`devices` list, then a clean exit.
