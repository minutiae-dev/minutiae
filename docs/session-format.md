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

During capture, audio is written two ways at once:

- **`audio-<ch>.part.wav`** — mono 16-bit PCM at the capture rate, appended synchronously. This is the crash-safe copy; a truncated WAV still holds every sample written. (The `.wav` extension must be last so AVAudioFile infers the container.)
- **`audio-<ch>.caf`** — Opus, encoded *incrementally* on a background queue as the session runs. Opus in CAF is not crash-safe — the packet table is only written on close — which is exactly why the WAV exists alongside it.

On stop the encoder drains its sub-second backlog, the CAF closes and the WAV is deleted. Stop is therefore O(1), not O(session length): a one-hour meeting finalizes in ~0.1 s rather than the ~40 s a whole-file transcode took. If the incremental encode ever fails (or falls more than 30 s behind), the complete WAV is transcoded in one go at stop instead; if that fails too, the WAV is kept and reported honestly as `codec: "pcm"` / `container: "wav"`.

The recording is persisted **mono, 16-bit, and encoded at 16 kHz** (or the capture rate, whichever is lower — a 16 kHz AirPods mic is never upsampled). Mono because both channels are speech destined for a transcript and the system tap is a stereo mix with no spatial information worth keeping; 16 kHz because that is exactly the rate the ASR consumes, so re-transcribing an archived session feeds the model the same input it had live. That is ~6 MB per channel-hour (measured ~13 MB/h for both channels together), and ~0.65 GB/h of scratch WAV during the session. Note that Apple's CAF/Opus writer prepends a fixed ~0.23 MB header to every file regardless of length, so very short recordings are disproportionately large — it is 4% of an hour-long meeting and 90% of a 25-second one.

`transcript.json` is flushed incrementally (write-temp-then-rename) every 20 segments or 10 s, so a crash loses ≤ 10 s of text.

## session.json

```json
{
  "schema_version": 1,
  "session_id": "01J9XYZ…",
  "started_at": "2026-06-10T14:30:22Z",
  "ended_at": "2026-06-10T15:14:03Z",
  "duration_s": 2621.4,
  "engine": "parakeet-tdt-v3",
  "language": "auto",
  "app_version": "0.1.0",
  "devices": {
    "mic": { "uid": "…", "name": "AirPods Pro", "sample_rate": 24000 },
    "system": { "uid": "process-tap", "name": "System audio", "sample_rate": 48000 }
  },
  "audio": [
    { "channel": "me",   "file": "audio-me.caf",   "codec": "opus", "container": "caf", "sample_rate": 16000, "duration_s": 2621.4 },
    { "channel": "them", "file": "audio-them.caf", "codec": "opus", "container": "caf", "sample_rate": 16000, "duration_s": 2621.4 }
  ],
  "title": null,
  "calendar_event": null
}
```

`devices.*.sample_rate` is what the **capture device** delivered; `audio[].sample_rate` is the rate of the **file**. They differ whenever the capture rate is above the 16 kHz encode cap, which is the normal case for the system tap.

Every file in `audio[]` starts at **session time zero** and is silence-padded
across any stretch its source did not deliver — the system-audio tap produces
nothing while the output device is idle, so without padding `audio-them` would
begin at the first sound rather than at the start of the meeting. Both channels
therefore span the whole session and their `duration_s` agree to within one IO
buffer, and a transcript timestamp indexes both recordings directly.

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
