# LLM sidecar IPC protocol v1

Transport: newline-delimited JSON (NDJSON). Requests flow core → llm on **stdin**; responses and events flow llm → core on **stdout**. Human-readable logs go to **stderr** only. One JSON object per line; no pretty-printing on the wire.

This is a **separate** sidecar from the audio engine (`sidecar-ipc-v1.md`). The `minutiae-llm` binary owns on-device LLM inference (MLX / Qwen3.5 today; llama.cpp and a BYO OpenAI-compatible HTTP backend later sit behind the same Rust `LlmBackend` trait). It is spawned **lazily** — only when enhancement is first requested — and may be shut down after idle to protect the <250 MB idle-RAM target.

This document is the source of truth. Hand-mirrored implementations:

- Rust: `app/src-tauri/src/llm_protocol.rs`
- Swift: `llm-engine/Sources/minutiae-llm/IPC/Messages.swift`

Change all three together. Round-trip tests on each side guard drift.

## Design

The sidecar is a **pure completion engine**: it receives a fully-assembled prompt and streams generated text back. It does **not** read session files, apply templates, or write output. The core:

- reads `transcript.json` + `scratchpad.md`, applies the template, and assembles the `prompt` (and optional `system`);
- accumulates the streamed `llm_token` text and writes `<Title>.md` (with YAML frontmatter from `session.json`) into the user's vault.

Text crosses IPC freely here (unlike audio in the engine sidecar), so keeping file/vault/frontmatter policy in the core lets the HTTP (BYO) and llama.cpp backends drop in behind the same trait without touching the sidecar.

## Envelope

Every message carries `"v": 1` and `"type": "<snake_case>"`. Requests carry an `"id"` (string, caller-chosen, unique per process lifetime) which is echoed on the direct response and on every streamed event belonging to that request. Pure events (`model_progress`) carry no `id`.

Forward compatibility: receivers MUST ignore unknown fields and unknown message types.

Lifecycle coupling: EOF on the sidecar's stdin means shut down cleanly (cancel any in-flight generation, exit 0).

## Core → llm

| type | fields | notes |
|---|---|---|
| `hello` | `id` | first message after spawn |
| `prepare_model` | `id`, `model` | optional pre-warm: ensure `model` is downloaded and loaded into memory. Idempotent. Progress streams as `model_progress`; completion is the correlated `model_ready`, failure an `error` (`model_download_failed` / `model_load_failed`). `enhance` also loads on demand, so this is purely to hide latency. |
| `enhance` | `id`, `model`, `prompt`, `system?`, `options` | run one streamed completion. Loads `model` on demand if not resident. Streams `llm_token` (same `id`), then a terminal `llm_done` (same `id`); failure an `error`. One generation is active at a time. See Options. |
| `cancel` | `id`, `request_id` | stop the in-flight `enhance` whose id is `request_id`. The generation ends with `llm_done` (`finish_reason: "cancelled"`). No-op if nothing is running. |
| `ping` | `id` | health check |
| `shutdown` | — | graceful exit; equivalent to stdin EOF |

### Options

```json
{
  "max_tokens": 1024,
  "temperature": 0.6,        // optional override; omit to use the per-mode preset
  "enable_thinking": false   // false = instruct (straight to answer); true = reason first
}
```

`enable_thinking` maps to the Qwen3.5 chat-template kwarg of the same name (passed via the sidecar's `additionalContext`). `false` makes the template emit an empty `<think></think>` so the model answers directly; `true` makes it reason inside `<think>…</think>` first. Qwen3.5 does **not** support the `/think` `/no_think` soft switches — do not rely on them. When `temperature` is omitted the sidecar applies the model card's per-mode "general" sampling preset (instruct: temp 0.7, top_p 0.8; thinking: temp 1.0, top_p 0.95; both top_k 20, min_p 0, presence_penalty 1.5). All fields optional; the sidecar supplies defaults.

## llm → core

| type | fields | notes |
|---|---|---|
| `hello_ack` | `id`, `protocol_version`, `runtime`, `loaded_model` | `runtime`: e.g. `"mlx"`; `loaded_model`: model id currently resident, or `null` |
| `model_progress` | `pct`, `stage` | emitted while a model loads; `stage`: `"downloading" \| "loading"` |
| `model_ready` | `id`, `model` | correlated response to `prepare_model`: `model` is downloaded and resident |
| `llm_token` | `id`, `text` | a streamed chunk of generated text for the `enhance` request `id`; concatenate in arrival order |
| `llm_done` | `id`, `finish_reason`, `stats` | terminal for an `enhance`. `finish_reason`: `"stop" \| "length" \| "cancelled"`. See Stats |
| `error` | `code`, `message`, `fatal`, `request_id?` | see Error codes; `request_id` ties it to an `enhance`/`prepare_model` if applicable |
| `pong` | `id` | |

### Stats

```json
{
  "prompt_tokens": 4120,
  "completion_tokens": 86,
  "duration_ms": 5100,
  "tokens_per_s": 16.9
}
```

### Error codes

`model_download_failed` · `model_load_failed` · `generation_failed` · `bad_request` · `internal`

`fatal: true` means the sidecar process is no longer usable and will exit; the core respawns it (or re-spawns lazily on the next enhance).

## Versioning

`v` bumps only on incompatible changes. Additive fields/messages do not bump `v`. The `model` string on `enhance` plus `runtime` in `hello_ack` are the seam for future backends (llama.cpp, BYO OpenAI-compatible HTTP) — same protocol where it applies, swapped behind the Rust `LlmBackend` trait.
