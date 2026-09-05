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
| `hello` | `id`, `engine?` | first message after spawn. `engine` is optional (additive) and names the user's selected model, e.g. `"nemotron-streaming-en"`, so `hello_ack.models_ready` reports on that variant instead of the engine default; omitted ⇒ the engine default. |
| `prepare_models` | `id`, `engine?`, `language?` | ensure the engine's ASR models are downloaded, compiled and loaded. Idempotent; safe to call when already ready. The core sends this automatically after the handshake when `hello_ack.models_ready` is `false`, so the download happens at launch rather than at first `start_session`. `engine`/`language` are optional (additive) and select which model to prepare, e.g. `"parakeet-tdt-v3"` / `"auto"`; omitted ⇒ the engine default. Progress streams as `model_progress`; completion is the correlated `models_ready` response, failure an `error` (`model_download_failed`). |
| `list_devices` | `id` | input (mic) devices |
| `start_session` | `id`, `session_id`, `dir`, `mic_device_uid`, `engine`, `language`, `them_source?` | `dir` is an existing, writable session folder; `engine` is an engine id: `"parakeet-tdt-v3"` (batch Parakeet TDT, multilingual, the default), `"nemotron-streaming-ml"` or `"nemotron-streaming-en"`; `language` BCP-47-ish, e.g. `"auto"` or `"en"`. `them_source` selects the "them" channel: `"system"` (default, the system-audio process tap) or an input-device UID to capture that device directly (e.g. a loopback like BlackHole). Omitted ⇒ `"system"`. |
| `stop_session` | `id` | stops the active session; finalization is async — completion is signalled by `session_stopped` |
| `ping` | `id` | health check |
| `shutdown` | — | graceful exit; equivalent to stdin EOF |

## Engine → core

| type | fields | notes |
|---|---|---|
| `hello_ack` | `id`, `protocol_version`, `engine_versions`, `models_ready` | `engine_versions: {"parakeet-tdt-v3": "<semver/model rev>", "nemotron-streaming-ml": "…", "nemotron-streaming-en": "…"}`; `models_ready: bool` (the model named by `hello.engine`, else the default, is completely present in the local cache — every required CoreML artifact, not just its metadata) |
| `models_ready` | `id` | correlated response to `prepare_models`: models are now downloaded, compiled and loaded |
| `devices` | `id`, `items`, `output?` | `items: [{uid, name, sample_rate, is_default}]`. `output` is optional (additive): `{name, transport, route}` describing the current media **output** device, where `route` is `"speakers"` \| `"headphones"` \| `"unknown"` — the engine's advisory read on whether the far end also reaches the mic acoustically, so the UI can suggest a headset before recording. Deliberately reports `"unknown"` when ambiguous. **Never** a gate for echo suppression, which decides from envelope correlation. |
| `session_started` | `id`, `session_id`, `t0_epoch_ms` | `t0_epoch_ms` anchors session-relative seconds to wall clock |
| `model_progress` | `pct`, `stage` | emitted during model download/compile (driven by `prepare_models` at launch, or by `start_session` as a fallback); `stage`: `"downloading" \| "compiling"` |
| `transcript` | `session_id`, `segment` | see Segment below |
| `levels` | `session_id`, `me_db`, `them_db` | ~10 Hz while recording; dBFS floats (≤ 0, −120 = silence) |
| `session_stopped` | `id`, `session_id`, `audio`, `stats` | `audio: [{channel, path, codec, container, duration_s, sample_rate, source_sample_rate?}]`; `stats: {segments, dropped_windows}`. `sample_rate` is the rate of the **file** (the recording is encoded at 16 kHz, or the capture rate if lower); `source_sample_rate` is optional (additive) and reports what the **capture device** delivered, which is what the core stores as the session's device metadata. Omitted ⇒ assume it equals `sample_rate`. |
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
