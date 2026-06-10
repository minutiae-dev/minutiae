# Sidecar IPC protocol v1

Transport: newline-delimited JSON (NDJSON). Requests flow core → engine on **stdin**; responses and events flow engine → core on **stdout**. Human-readable logs go to **stderr** only. One JSON object per line; no pretty-printing on the wire.

This document is the source of truth. Hand-mirrored implementations:

- Rust: `app/src-tauri/src/protocol.rs`
- Swift: `engine/Sources/EngineCore/IPC/Messages.swift`

Change all three together. Round-trip tests on each side guard drift.

## Envelope

Every message carries `"v": 1` and `"type": "<snake_case>"`. Requests carry an `"id"` (string, caller-chosen, unique per process lifetime) which is echoed on the direct response. Events (transcript, levels, model_progress, errors) carry no `id`.

Forward compatibility: receivers MUST ignore unknown fields and unknown message types.

Lifecycle coupling: EOF on the engine's stdin means shut down cleanly (stop any active session, flush, exit 0).

## Core → engine

| type | fields | notes |
|---|---|---|
| `hello` | `id` | first message after spawn |
| `list_devices` | `id` | input (mic) devices |
| `start_session` | `id`, `session_id`, `dir`, `mic_device_uid`, `engine`, `language` | `dir` is an existing, writable session folder; `engine` is an engine id, e.g. `"parakeet-tdt-v3"`; `language` BCP-47-ish, e.g. `"en"` |
| `stop_session` | `id` | stops the active session; finalization is async — completion is signalled by `session_stopped` |
| `ping` | `id` | health check |
| `shutdown` | — | graceful exit; equivalent to stdin EOF |

## Engine → core

| type | fields | notes |
|---|---|---|
| `hello_ack` | `id`, `protocol_version`, `engine_versions`, `models_ready` | `engine_versions: {"parakeet-tdt-v3": "<semver/model rev>"}`; `models_ready: bool` |
| `devices` | `id`, `items` | `items: [{uid, name, sample_rate, is_default}]` |
| `session_started` | `id`, `session_id`, `t0_epoch_ms` | `t0_epoch_ms` anchors session-relative seconds to wall clock |
| `model_progress` | `pct`, `stage` | emitted during first-run model download/compile; `stage`: `"downloading" \| "compiling"` |
| `transcript` | `session_id`, `segment` | see Segment below |
| `levels` | `session_id`, `me_db`, `them_db` | ~10 Hz while recording; dBFS floats (≤ 0, −120 = silence) |
| `session_stopped` | `id`, `session_id`, `audio`, `stats` | `audio: [{channel, path, codec, container, duration_s, sample_rate}]`; `stats: {segments, dropped_windows}` |
| `error` | `code`, `message`, `fatal`, `session_id?` | see Error codes |
| `pong` | `id` | |

### Segment

```json
{
  "idx": 42,
  "channel": "me",          // "me" | "them"  (M4 adds "them:spk1" sub-labels)
  "t0": 12.48,              // seconds from session start, float
  "t1": 17.02,
  "text": "…",
  "confidence": 0.93,       // 0..1, engine-reported; -1 if unavailable
  "final": true,            // non-final segments may be re-emitted with the same idx; replace in place
  "engine": "parakeet-tdt-v3"
}
```

`idx` is unique per session per channel-agnostic stream (monotonic across both channels). Only `final: true` segments are persisted to `transcript.json`.

### Error codes

`tcc_denied_mic` · `tcc_denied_system` · `tap_failed` · `device_gone` · `model_download_failed` · `session_already_active` · `no_active_session` · `bad_request` · `internal`

`fatal: true` means the engine process is no longer usable and will exit; the core respawns it.

## Versioning

`v` bumps only on incompatible changes. Additive fields/messages do not bump `v`. The `engine` string on `start_session` and segments is the seam for future engines (WhisperKit fallback, Windows sherpa-onnx sidecar) — same protocol, different `engine_versions` advertised in `hello_ack`.
