# Minutiae

Local-first meeting notepad for macOS. Captures your mic and system audio without a meeting bot, shows a live transcript next to your scratchpad, and after the meeting writes a polished Markdown note into any folder you choose (natively Obsidian-compatible). Nothing ever touches a server.

## Status

Milestone 1 (capture + live transcript) in progress. See `docs/milestones.md`.

## Requirements

- Apple Silicon Mac, macOS 14.4+
- Xcode 16+ (Swift 6 toolchain)
- Rust stable, Node 22+, pnpm

## Architecture

```
┌────────────────────────────┐     NDJSON over stdio      ┌──────────────────────────────┐
│  Tauri 2 app               │ ◄────────────────────────► │  minutiae-engine (Swift)     │
│  Rust core + Svelte 5 UI   │   docs/protocol/…v1.md     │  Core Audio process tap      │
│  session state, persistence│                            │  AVAudioEngine mic capture   │
│                            │                            │  FluidAudio (Parakeet, ANE)  │
└────────────────────────────┘                            └──────────────────────────────┘
```

- `app/` — Tauri 2 application: Rust core (`app/src-tauri`) and Svelte 5 frontend (`app/src`).
- `engine/` — Swift sidecar (SPM package). Owns audio capture and on-device ASR; writes audio to disk itself so raw audio never crosses IPC.
- `docs/` — protocol spec, session format, milestone outlines.

## Development

```sh
pnpm install
pnpm dev          # builds the sidecar, then runs `tauri dev`

# faster loops:
swift run --package-path engine minutiae-engine   # sidecar alone; type NDJSON on stdin
swift test --package-path engine
cargo test --manifest-path app/src-tauri/Cargo.toml
```
