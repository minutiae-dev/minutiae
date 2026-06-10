# On-disk session format (schema_version 1)

Sessions live under `~/Library/Application Support/Minutiae/sessions/` in M1. The M2 enhancement step reads a session folder and writes `<Title>.md` (YAML frontmatter mapped 1:1 from `session.json`) into the user-chosen vault folder — designed so no migration is needed.

```
sessions/2026-06-10T14-30-22Z--01J9XYZ…/    # <started_at, filesystem-safe>--<ulid>
├── session.json
├── transcript.json
├── audio-me.caf            # Opus in CAF (Apple's encoder doesn't mux Ogg)
├── audio-them.caf
└── scratchpad.md           # M2+; missing = empty
```

During capture, audio is written as append-only WAV (`audio-me.wav.part`, `audio-them.wav.part`) for crash safety, then transcoded to Opus/CAF on stop. `transcript.json` is flushed incrementally (write-temp-then-rename) every 20 segments or 10 s, so a crash loses ≤ 10 s of text.

## session.json

```json
{
  "schema_version": 1,
  "session_id": "01J9XYZ…",
  "started_at": "2026-06-10T14:30:22Z",
  "ended_at": "2026-06-10T15:14:03Z",
  "duration_s": 2621.4,
  "engine": "parakeet-tdt-v3",
  "language": "en",
  "app_version": "0.1.0",
  "devices": {
    "mic": { "uid": "…", "name": "AirPods Pro", "sample_rate": 24000 },
    "system": { "uid": "process-tap", "name": "System audio", "sample_rate": 48000 }
  },
  "audio": [
    { "channel": "me",   "file": "audio-me.caf",   "codec": "opus", "container": "caf", "sample_rate": 24000, "duration_s": 2621.4 },
    { "channel": "them", "file": "audio-them.caf", "codec": "opus", "container": "caf", "sample_rate": 48000, "duration_s": 2621.4 }
  ],
  "title": null,
  "calendar_event": null
}
```

`title` and `calendar_event` are frontmatter-ready nulls filled by M3 (EventKit).

## transcript.json

```json
{
  "schema_version": 1,
  "session_id": "01J9XYZ…",
  "segments": [
    { "idx": 0, "channel": "them", "t0": 1.20, "t1": 4.85, "text": "…", "confidence": 0.94, "final": true, "engine": "parakeet-tdt-v3" }
  ]
}
```

Only `final` segments are persisted. `t0`/`t1` are seconds from `started_at` (anchor: `t0_epoch_ms` from the engine). M4 diarization extends `channel` with `them:spk1`-style sub-labels and bumps `schema_version`.
