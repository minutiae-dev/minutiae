# Third-party software and models

Minutiae is MIT licensed (see `LICENSE`). It builds on the libraries below and
downloads machine-learning models onto the user's machine at runtime. Those
models are not part of this repository and carry their own licenses.

## Models downloaded at runtime

Nothing is downloaded until the app needs it: the ASR model on first launch,
the language model only when you press *Enhance* for the first time. All
downloads come from huggingface.co and are cached locally.

| Model | Used for | Hugging Face repo | License (as stated on the model card, checked 2026-09-05) |
|---|---|---|---|
| NVIDIA Parakeet TDT 0.6B v3 (CoreML conversion by FluidInference) | Default transcription engine, `parakeet-tdt-v3` | `FluidInference/parakeet-tdt-0.6b-v3-coreml`, from `nvidia/parakeet-tdt-0.6b-v3` | CC-BY-4.0 |
| NVIDIA Nemotron 3.5 ASR Streaming Multilingual 0.6B (CoreML) | Optional engine, `nemotron-streaming-ml` | `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` | OpenMDW-1.1 |
| NVIDIA Nemotron Speech Streaming EN 0.6B (CoreML) | Optional engine, `nemotron-streaming-en` | `FluidInference/nemotron-speech-streaming-en-0.6b-coreml`, from `nvidia/nemotron-speech-streaming-en-0.6b` | Card metadata says `nvidia-open-model-license`; its notes say Apache-2.0. Treat the NVIDIA Open Model License as governing until NVIDIA clarifies. |
| Qwen3.5-4B, 4-bit MLX quantisation | On-device enhancement (`llm-engine/`) | `mlx-community/Qwen3.5-4B-MLX-4bit`, from `Qwen/Qwen3.5-4B` | Apache-2.0 |

## Libraries

| Dependency | Where | License |
|---|---|---|
| FluidAudio 0.15.2 (pinned exact) | `engine/Package.swift` | Apache-2.0 |
| mlx-swift, mlx-swift-lm | `llm-engine/Package.swift` | MIT |
| swift-transformers, swift-huggingface | `llm-engine/Package.swift` | Apache-2.0 |
| Tauri 2, tauri-plugin-shell, tauri-plugin-dialog, tauri-plugin-deep-link | `app/src-tauri/Cargo.toml` | MIT or Apache-2.0 |
| serde, serde_json, thiserror, chrono, ulid, tracing, tokio and the other Rust crates | `app/src-tauri/Cargo.toml`, `engine-windows/Cargo.toml` | MIT or Apache-2.0 (see each crate) |
| windows (Windows sidecar) | `engine-windows/Cargo.toml` | MIT or Apache-2.0 |
| Svelte 5, Vite, TypeScript, @tauri-apps/api, marked | `app/package.json` | MIT |
| @lucide/svelte | `app/package.json` | ISC |
| dompurify | `app/package.json` | Apache-2.0 or MPL-2.0 |

Run `cargo license` (or `cargo tree`) and `pnpm licenses list` for the full,
current transitive lists.
