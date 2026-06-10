# Minutiae — agent notes

Local-first macOS meeting notepad. Tauri 2 (Rust core + Svelte 5) with a Swift sidecar (`engine/`) that owns audio capture and on-device ASR (FluidAudio/Parakeet on the Neural Engine).

## Invariants — do not violate

- **Audio never crosses IPC.** The Swift sidecar writes audio files itself; only control messages and transcript events go over stdio (NDJSON, spec: `docs/protocol/sidecar-ipc-v1.md`). The protocol doc is the source of truth; `app/src-tauri/src/protocol.rs` and `engine/Sources/EngineCore/IPC/Messages.swift` are hand-mirrored from it — change all three together.
- **Plain files are authoritative.** `.md` and session JSON on disk are the source of truth; any index (SQLite later) is derived and rebuildable.
- **No telemetry, no network calls** except model downloads (FluidAudio from HuggingFace) and user-configured BYO LLM endpoints (M2+).
- **Never force a format on audio input taps** — AirPods mics deliver 16/24 kHz; record native rate, resample only the ASR feed.
- **Silence must produce zero transcript segments** (RMS gate before ASR). This is a marketed differentiator; there is a test for it.
- All persisted JSON carries `schema_version`.

## Non-functional targets (these are the product)

Idle RAM < 250 MB · capture start < 1 s · 100% offline path · no hallucinated text during pauses.

## Build/test

```sh
pnpm dev                                            # sidecar build + tauri dev
swift test --package-path engine
cargo test --manifest-path app/src-tauri/Cargo.toml
scripts/build-sidecar.sh [release]                  # → app/src-tauri/binaries/minutiae-engine-aarch64-apple-darwin
```

Sidecar is pure SPM (no .xcodeproj). Info.plist is embedded into the binary via `-sectcreate` linker flags in `Package.swift` (needed for TCC usage strings); the build script ad-hoc codesigns with the audio-input entitlement.

## Gotchas

- Core Audio process taps require macOS 14.4+ and the `NSAudioCaptureUsageDescription` TCC prompt. In dev, TCC attribution may roll up to the terminal; fallback is granting permission to the sidecar standalone via `swift run`.
- Apple's Opus encoder only muxes into CAF (not Ogg); session metadata records `container: "caf"`.
- FluidAudio is pinned `.exact` in `engine/Package.swift` — 0.x API churn; bump deliberately.
