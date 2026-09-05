# llm-engine — M2 LLM sidecar

The `minutiae-llm` sidecar: on-device LLM enhancement of a finished session
(`transcript.json` + `scratchpad.md` → `<Title>.md` in the vault) via
[mlx-swift](https://github.com/ml-explore/mlx-swift) +
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), MLX → Apple GPU/ANE.

Two executables:

- **`minutiae-llm`** — the real sidecar. NDJSON over stdio
  (`docs/protocol/llm-ipc-v1.md`); a pure completion engine (prompt in → tokens
  out). The Rust core (`app/src-tauri/src/llm.rs`) spawns it lazily on the first
  *Enhance*, assembles the prompt, and writes the vault `.md`.
- **`minutiae-llm-spike`** — a standalone diagnostic that loads a model and
  streams a completion (retired the integration risk; handy for quick checks).

## Install for the app

```sh
scripts/build-llm-sidecar.sh [release|debug]   # release recommended
```

xcodebuilds `minutiae-llm` and installs the binary **with its
`mlx-swift_Cmlx.bundle` metallib** into `app/src-tauri/target/<profile>/` (where
the Tauri dev build spawns it) plus a stash in `binaries/`. It is intentionally
**not** in `pnpm dev`'s `beforeDevCommand` (the MLX build is slow/heavy); run it
once, and after pulling `llm-engine` changes. Bundling into the signed `.app`
(externalBin + tauri#11992) is M5.

## Hard requirements (learned the hard way — see below)

- **Xcode 16.4+ (Swift 6.1.2+).** mlx-swift-lm's manifest is `swift-tools-version: 6.1`,
  and the `qwen3_5` architecture (Qwen3.5) only exists in its 3.x line, which requires it.
  Xcode 16.2 (Swift 6.0.3) cannot even parse the manifest, and a standalone newer
  toolchain breaks Xcode 16.2's build driver (`-disallow-use-new-driver`). One
  consistent Xcode ≥16.4 is the only clean path.
- **Must build with `xcodebuild`, not `swift build`.** Plain SwiftPM cannot compile
  MLX's Metal shaders (documented in mlx-swift's README); only the Xcode build system
  runs the Metal phase that produces `default.metallib`.

## Build

```sh
xcodebuild build -scheme minutiae-llm \
  -destination 'platform=macOS' \
  -derivedDataPath .xcode-dd \
  -configuration Release \
  -skipMacroValidation
```

- `-skipMacroValidation` — the HuggingFace integration uses Swift macros
  (`MLXHuggingFaceMacros`); without this flag CLI builds fail with "Macro … must be
  enabled before it can be used" (the GUI's Trust & Enable prompt has no CLI consent).
- The scheme is `minutiae-llm` (the package name), not the target name.
- Output: `.xcode-dd/Build/Products/<config>/minutiae-llm-spike`, with the Metal
  library colocated at `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` —
  MLX finds it relative to the binary, so the sidecar must ship that bundle alongside it.

## Run

```sh
./.xcode-dd/Build/Products/Release/minutiae-llm-spike [model-id] [prompt]
```

Default model `mlx-community/Qwen3.5-4B-MLX-4bit`. Models download once to
`~/.cache/huggingface/` (~2.85 GB for this one — it bundles vision weights).

## Spike results (2026-06-12, M3, Debug build)

- ✅ Loads `Qwen3.5-4B-MLX-4bit` in **4.7 s** (cached); Metal initializes; streams.
- ⚠️ **Reasoning model** — emits a large `<think>` block before the answer. For
  enhancement, set `enable_thinking=false` (Qwen `/no_think`) unless thinking is wanted.
- ⚠️ **~17 tok/s** (67 char/s) in Debug — Release expected faster; fine for batch use.

## Deps (pins)

- `mlx-swift-lm` @ `main` (has `qwen3_5`; pin a tag once a release we trust ships it,
  e.g. `3.31.3` also registers `qwen3_5` and targets Swift 6.1).
- `swift-huggingface` ≥ 0.9.0 (`HuggingFace` — Hub downloader).
- `swift-transformers` ≥ 1.3.0 (`Tokenizers`).
