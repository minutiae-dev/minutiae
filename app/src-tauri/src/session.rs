//! Session state machine and on-disk session writer.
//!
//! State machine: `Idle → Starting → Recording → Stopping → Idle` with
//! `Error` as the failure terminal (a new session may start from `Error`).
//! Single active session.
//!
//! On-disk format: `docs/session-format.md` (schema_version 1).
//! `transcript.json` is flushed via write-temp-then-rename every
//! [`FLUSH_SEGMENTS`] final segments or [`FLUSH_INTERVAL`], so a crash loses
//! at most ~10 s of text.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::Serialize;

use crate::protocol::{AudioFileInfo, Segment};

pub const SCHEMA_VERSION: u32 = 1;
pub const FLUSH_SEGMENTS: usize = 20;
pub const FLUSH_INTERVAL: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Idle,
    Starting,
    Recording,
    Stopping,
    Error,
}

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("invalid state: expected {expected}, was {actual:?}")]
    InvalidState {
        expected: &'static str,
        actual: Phase,
    },
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone)]
pub struct MicInfo {
    pub uid: String,
    pub name: String,
    pub sample_rate: u32,
}

#[derive(Debug)]
struct ActiveSession {
    session_id: String,
    dir: PathBuf,
    started_at: DateTime<Utc>,
    t0_epoch_ms: Option<u64>,
    engine: String,
    language: String,
    mic: MicInfo,
    /// Final segments only, ordered by arrival (engine idx is monotonic).
    segments: Vec<Segment>,
    unflushed: usize,
    last_flush: Instant,
}

#[derive(Debug, Clone)]
pub struct StartInfo {
    pub session_id: String,
    pub dir: PathBuf,
}

#[derive(Debug, Clone)]
pub struct FinalizedSession {
    pub session_id: String,
    pub dir: PathBuf,
    pub duration_s: f64,
    pub segments: usize,
}

#[derive(Debug, Clone)]
pub struct AbortedSession {
    pub session_id: String,
    pub dir: PathBuf,
}

pub struct SessionMachine {
    app_version: String,
    phase: Phase,
    active: Option<ActiveSession>,
}

impl SessionMachine {
    pub fn new(app_version: impl Into<String>) -> Self {
        Self {
            app_version: app_version.into(),
            phase: Phase::Idle,
            active: None,
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn session_id(&self) -> Option<&str> {
        self.active.as_ref().map(|a| a.session_id.as_str())
    }

    pub fn t0_epoch_ms(&self) -> Option<u64> {
        self.active.as_ref().and_then(|a| a.t0_epoch_ms)
    }

    /// Idle/Error → Starting. Creates the session folder
    /// `<sessions_root>/<ISO-ts-filesystem-safe>--<ulid>/`.
    pub fn begin_starting(
        &mut self,
        sessions_root: &Path,
        mic: MicInfo,
        engine: &str,
        language: &str,
    ) -> Result<StartInfo, SessionError> {
        match self.phase {
            Phase::Idle | Phase::Error => {}
            actual => {
                return Err(SessionError::InvalidState {
                    expected: "idle or error",
                    actual,
                })
            }
        }

        let started_at = Utc::now();
        let session_id = ulid::Ulid::new().to_string();
        let dir = sessions_root.join(format!(
            "{}--{}",
            started_at.format("%Y-%m-%dT%H-%M-%SZ"),
            session_id
        ));
        std::fs::create_dir_all(&dir)?;

        self.active = Some(ActiveSession {
            session_id: session_id.clone(),
            dir: dir.clone(),
            started_at,
            t0_epoch_ms: None,
            engine: engine.to_string(),
            language: language.to_string(),
            mic,
            segments: Vec::new(),
            unflushed: 0,
            last_flush: Instant::now(),
        });
        self.phase = Phase::Starting;
        Ok(StartInfo { session_id, dir })
    }

    /// Starting → Recording (on `session_started`).
    pub fn mark_recording(&mut self, t0_epoch_ms: u64) -> Result<(), SessionError> {
        if self.phase != Phase::Starting {
            return Err(SessionError::InvalidState {
                expected: "starting",
                actual: self.phase,
            });
        }
        if let Some(active) = self.active.as_mut() {
            active.t0_epoch_ms = Some(t0_epoch_ms);
        }
        self.phase = Phase::Recording;
        Ok(())
    }

    /// Recording → Stopping.
    pub fn begin_stopping(&mut self) -> Result<(), SessionError> {
        if self.phase != Phase::Recording {
            return Err(SessionError::InvalidState {
                expected: "recording",
                actual: self.phase,
            });
        }
        self.phase = Phase::Stopping;
        Ok(())
    }

    /// Accumulate a segment. Only `final` segments are persisted; a final
    /// segment re-emitted with an existing `idx` replaces it in place.
    /// Segments for an unknown session id (or while not capturing) are
    /// ignored. May flush transcript.json (every 20 segments / 10 s).
    pub fn on_segment(&mut self, session_id: &str, segment: &Segment) -> Result<(), SessionError> {
        if !matches!(self.phase, Phase::Recording | Phase::Stopping) {
            return Ok(());
        }
        let Some(active) = self.active.as_mut() else {
            return Ok(());
        };
        if active.session_id != session_id || !segment.is_final {
            return Ok(());
        }

        match active.segments.iter_mut().find(|s| s.idx == segment.idx) {
            Some(existing) => *existing = segment.clone(),
            None => active.segments.push(segment.clone()),
        }
        active.unflushed += 1;
        self.flush_if_due()
    }

    /// Flush transcript.json if 20+ unflushed segments or 10 s elapsed since
    /// the last flush. Cheap no-op otherwise; safe to call from a timer.
    pub fn flush_if_due(&mut self) -> Result<(), SessionError> {
        let Some(active) = self.active.as_mut() else {
            return Ok(());
        };
        if active.unflushed == 0 {
            return Ok(());
        }
        if active.unflushed >= FLUSH_SEGMENTS || active.last_flush.elapsed() >= FLUSH_INTERVAL {
            Self::write_transcript(active)?;
        }
        Ok(())
    }

    /// Stopping → Idle. Writes the final transcript.json and session.json.
    pub fn finalize(
        &mut self,
        audio: &[AudioFileInfo],
        ended_at: DateTime<Utc>,
    ) -> Result<FinalizedSession, SessionError> {
        if self.phase != Phase::Stopping {
            return Err(SessionError::InvalidState {
                expected: "stopping",
                actual: self.phase,
            });
        }
        let Some(mut active) = self.active.take() else {
            return Err(SessionError::InvalidState {
                expected: "stopping with an active session",
                actual: self.phase,
            });
        };

        Self::write_transcript(&mut active)?;

        let wall_duration =
            (ended_at - active.started_at).num_milliseconds().max(0) as f64 / 1000.0;
        let duration_s = audio
            .iter()
            .map(|a| a.duration_s)
            .fold(0.0_f64, f64::max)
            .max(0.0);
        let duration_s = if duration_s > 0.0 {
            duration_s
        } else {
            wall_duration
        };
        // The DEVICE rate, not the file's: the recording is encoded at 16 kHz
        // regardless of what the tap delivered, and this field describes the
        // capture device.
        let system_sample_rate = audio
            .iter()
            .find(|a| a.channel == "them")
            .map(|a| a.device_sample_rate())
            .unwrap_or(48_000);

        let session_json = SessionJson {
            schema_version: SCHEMA_VERSION,
            session_id: active.session_id.clone(),
            started_at: active
                .started_at
                .to_rfc3339_opts(SecondsFormat::Secs, true),
            ended_at: ended_at.to_rfc3339_opts(SecondsFormat::Secs, true),
            duration_s,
            engine: active.engine.clone(),
            language: active.language.clone(),
            app_version: self.app_version.clone(),
            devices: DevicesJson {
                mic: DeviceJson {
                    uid: active.mic.uid.clone(),
                    name: active.mic.name.clone(),
                    sample_rate: active.mic.sample_rate,
                },
                system: DeviceJson {
                    uid: "process-tap".into(),
                    name: "System audio".into(),
                    sample_rate: system_sample_rate,
                },
            },
            audio: audio
                .iter()
                .map(|a| AudioJson {
                    channel: a.channel.clone(),
                    file: Path::new(&a.path)
                        .file_name()
                        .map(|f| f.to_string_lossy().into_owned())
                        .unwrap_or_else(|| a.path.clone()),
                    codec: a.codec.clone(),
                    container: a.container.clone(),
                    sample_rate: a.sample_rate,
                    duration_s: a.duration_s,
                })
                .collect(),
            title: None,
            calendar_event: None,
        };
        write_json_atomic(&active.dir.join("session.json"), &session_json)?;

        self.phase = Phase::Idle;
        Ok(FinalizedSession {
            session_id: active.session_id,
            dir: active.dir,
            duration_s,
            segments: active.segments.len(),
        })
    }

    /// Abort the active session (engine crash, failed start/stop). Best-effort
    /// flushes whatever final segments we have, then moves to Error. No-op
    /// (stays Idle) when nothing is active.
    pub fn abort(&mut self) -> Option<AbortedSession> {
        let active = self.active.take();
        match active {
            Some(mut a) => {
                if !a.segments.is_empty() {
                    if let Err(e) = Self::write_transcript(&mut a) {
                        tracing::warn!("failed to flush transcript on abort: {e}");
                    }
                }
                self.phase = Phase::Error;
                Some(AbortedSession {
                    session_id: a.session_id,
                    dir: a.dir,
                })
            }
            None => {
                if self.phase != Phase::Idle {
                    self.phase = Phase::Error;
                }
                None
            }
        }
    }

    fn write_transcript(active: &mut ActiveSession) -> Result<(), SessionError> {
        let transcript = TranscriptJson {
            schema_version: SCHEMA_VERSION,
            session_id: active.session_id.clone(),
            segments: &active.segments,
        };
        write_json_atomic(&active.dir.join("transcript.json"), &transcript)?;
        active.unflushed = 0;
        active.last_flush = Instant::now();
        Ok(())
    }

    #[cfg(test)]
    fn set_last_flush_for_test(&mut self, t: Instant) {
        if let Some(a) = self.active.as_mut() {
            a.last_flush = t;
        }
    }
}

/// Write-temp-then-rename so readers never observe a torn file.
fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<(), SessionError> {
    let mut bytes = serde_json::to_vec_pretty(value)?;
    bytes.push(b'\n');
    let file_name = path
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_else(|| "out.json".into());
    let tmp = path.with_file_name(format!("{file_name}.tmp"));
    std::fs::write(&tmp, &bytes)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// On-disk shapes (docs/session-format.md, schema_version 1)

#[derive(Serialize)]
struct TranscriptJson<'a> {
    schema_version: u32,
    session_id: String,
    segments: &'a [Segment],
}

#[derive(Serialize)]
struct SessionJson {
    schema_version: u32,
    session_id: String,
    started_at: String,
    ended_at: String,
    duration_s: f64,
    engine: String,
    language: String,
    app_version: String,
    devices: DevicesJson,
    audio: Vec<AudioJson>,
    /// Frontmatter-ready null, filled by M3 (EventKit).
    title: Option<String>,
    /// Frontmatter-ready null, filled by M3 (EventKit).
    calendar_event: Option<serde_json::Value>,
}

#[derive(Serialize)]
struct DevicesJson {
    mic: DeviceJson,
    system: DeviceJson,
}

#[derive(Serialize)]
struct DeviceJson {
    uid: String,
    name: String,
    sample_rate: u32,
}

#[derive(Serialize)]
struct AudioJson {
    channel: String,
    file: String,
    codec: String,
    container: String,
    sample_rate: u32,
    duration_s: f64,
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn mic() -> MicInfo {
        MicInfo {
            uid: "BuiltInMicrophoneDevice".into(),
            name: "MacBook Pro Microphone".into(),
            sample_rate: 48_000,
        }
    }

    fn seg(idx: u64, is_final: bool, text: &str) -> Segment {
        Segment {
            idx,
            channel: if idx % 2 == 0 { "me" } else { "them" }.into(),
            t0: idx as f64,
            t1: idx as f64 + 0.9,
            text: text.into(),
            confidence: 0.9,
            is_final,
            engine: "nemotron-streaming-ml".into(),
        }
    }

    fn audio(dir: &Path) -> Vec<AudioFileInfo> {
        vec![
            AudioFileInfo {
                channel: "me".into(),
                path: dir.join("audio-me.caf").to_string_lossy().into_owned(),
                codec: "opus".into(),
                container: "caf".into(),
                duration_s: 2621.4,
                // Encoded at 16 kHz from a 24 kHz AirPods mic.
                sample_rate: 16_000,
                source_sample_rate: Some(24_000),
            },
            AudioFileInfo {
                channel: "them".into(),
                path: dir.join("audio-them.caf").to_string_lossy().into_owned(),
                codec: "opus".into(),
                container: "caf".into(),
                duration_s: 2621.4,
                // Encoded at 16 kHz from the 48 kHz system tap.
                sample_rate: 16_000,
                source_sample_rate: Some(48_000),
            },
        ]
    }

    fn read_json(path: &Path) -> Value {
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn full_lifecycle_writes_session_and_transcript() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");
        assert_eq!(m.phase(), Phase::Idle);

        let info = m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        assert_eq!(m.phase(), Phase::Starting);
        assert!(info.dir.is_dir());
        let dir_name = info.dir.file_name().unwrap().to_string_lossy().into_owned();
        assert!(
            dir_name.ends_with(&format!("--{}", info.session_id)),
            "dir name {dir_name} should end with --<ulid>"
        );
        assert!(dir_name.contains('T') && dir_name.contains("Z--"));
        assert!(!dir_name.contains(':'), "dir name must be filesystem-safe");

        m.mark_recording(1_770_000_000_000).unwrap();
        assert_eq!(m.phase(), Phase::Recording);
        assert_eq!(m.t0_epoch_ms(), Some(1_770_000_000_000));

        m.on_segment(&info.session_id, &seg(0, true, "hello")).unwrap();
        m.on_segment(&info.session_id, &seg(1, false, "partial")).unwrap();
        m.on_segment("someone-else", &seg(2, true, "other session")).unwrap();

        m.begin_stopping().unwrap();
        assert_eq!(m.phase(), Phase::Stopping);
        // segments may still trail in while stopping
        m.on_segment(&info.session_id, &seg(3, true, "tail")).unwrap();

        let done = m
            .finalize(&audio(&info.dir), Utc::now())
            .unwrap();
        assert_eq!(m.phase(), Phase::Idle);
        assert_eq!(done.segments, 2);

        let transcript = read_json(&info.dir.join("transcript.json"));
        assert_eq!(transcript["schema_version"], 1);
        assert_eq!(transcript["session_id"], info.session_id.as_str());
        let segs = transcript["segments"].as_array().unwrap();
        assert_eq!(segs.len(), 2, "only final segments of this session persist");
        assert_eq!(segs[0]["idx"], 0);
        assert_eq!(segs[0]["final"], true);
        assert_eq!(segs[1]["idx"], 3);

        let session = read_json(&info.dir.join("session.json"));
        assert_eq!(session["schema_version"], 1);
        assert_eq!(session["session_id"], info.session_id.as_str());
        assert_eq!(session["engine"], "nemotron-streaming-ml");
        assert_eq!(session["language"], "en");
        assert_eq!(session["app_version"], "0.1.0");
        assert_eq!(session["duration_s"], 2621.4);
        // title/calendar_event must be present and null (frontmatter-ready)
        assert!(session.as_object().unwrap().contains_key("title"));
        assert!(session["title"].is_null());
        assert!(session.as_object().unwrap().contains_key("calendar_event"));
        assert!(session["calendar_event"].is_null());
        // started_at/ended_at look like 2026-06-10T14:30:22Z
        let started = session["started_at"].as_str().unwrap();
        assert!(started.ends_with('Z') && started.contains(':'));
        // devices
        assert_eq!(session["devices"]["mic"]["uid"], "BuiltInMicrophoneDevice");
        assert_eq!(session["devices"]["mic"]["sample_rate"], 48_000);
        assert_eq!(session["devices"]["system"]["uid"], "process-tap");
        assert_eq!(session["devices"]["system"]["name"], "System audio");
        assert_eq!(session["devices"]["system"]["sample_rate"], 48_000);
        // audio entries use bare file names
        assert_eq!(session["audio"][0]["file"], "audio-me.caf");
        assert_eq!(session["audio"][0]["codec"], "opus");
        assert_eq!(session["audio"][0]["container"], "caf");
        assert_eq!(session["audio"][1]["file"], "audio-them.caf");
        // no leftover temp files
        assert!(!info.dir.join("session.json.tmp").exists());
        assert!(!info.dir.join("transcript.json.tmp").exists());
    }

    #[test]
    fn invalid_transitions_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");

        assert!(m.mark_recording(0).is_err());
        assert!(m.begin_stopping().is_err());
        assert!(m.finalize(&[], Utc::now()).is_err());

        m.begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        // can't start twice
        assert!(m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .is_err());
        // can't stop or finalize from Starting
        assert!(m.begin_stopping().is_err());
        assert!(m.finalize(&[], Utc::now()).is_err());

        m.mark_recording(1).unwrap();
        // can't start or re-mark while recording
        assert!(m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .is_err());
        assert!(m.mark_recording(2).is_err());
        // can't finalize before stopping
        assert!(m.finalize(&[], Utc::now()).is_err());

        m.begin_stopping().unwrap();
        m.finalize(&[], Utc::now()).unwrap();
        assert_eq!(m.phase(), Phase::Idle);
    }

    #[test]
    fn restart_is_allowed_from_error() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");
        m.begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        let aborted = m.abort().unwrap();
        assert_eq!(m.phase(), Phase::Error);
        assert!(aborted.dir.is_dir());

        let info = m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        assert_eq!(m.phase(), Phase::Starting);
        assert_ne!(info.session_id, aborted.session_id);
    }

    #[test]
    fn flushes_every_20_segments() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");
        let info = m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        m.mark_recording(0).unwrap();

        let transcript = info.dir.join("transcript.json");
        for i in 0..19 {
            m.on_segment(&info.session_id, &seg(i, true, "x")).unwrap();
        }
        assert!(!transcript.exists(), "no flush before 20 segments");
        m.on_segment(&info.session_id, &seg(19, true, "x")).unwrap();
        assert!(transcript.exists(), "flush at the 20th segment");
        let v = read_json(&transcript);
        assert_eq!(v["segments"].as_array().unwrap().len(), 20);
    }

    #[test]
    fn flushes_after_interval() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");
        let info = m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        m.mark_recording(0).unwrap();

        m.on_segment(&info.session_id, &seg(0, true, "x")).unwrap();
        let transcript = info.dir.join("transcript.json");
        assert!(!transcript.exists());

        // pretend the last flush was 11 s ago
        m.set_last_flush_for_test(Instant::now() - Duration::from_secs(11));
        m.flush_if_due().unwrap();
        assert!(transcript.exists());
        let v = read_json(&transcript);
        assert_eq!(v["segments"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn final_segment_with_same_idx_replaces_in_place() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");
        let info = m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        m.mark_recording(0).unwrap();

        m.on_segment(&info.session_id, &seg(0, true, "draft")).unwrap();
        m.on_segment(&info.session_id, &seg(1, true, "second")).unwrap();
        m.on_segment(&info.session_id, &seg(0, true, "revised")).unwrap();

        m.begin_stopping().unwrap();
        m.finalize(&[], Utc::now()).unwrap();

        let v = read_json(&info.dir.join("transcript.json"));
        let segs = v["segments"].as_array().unwrap();
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0]["idx"], 0);
        assert_eq!(segs[0]["text"], "revised");
        assert_eq!(segs[1]["idx"], 1);
    }

    #[test]
    fn abort_flushes_partial_transcript_and_sets_error() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");
        let info = m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        m.mark_recording(0).unwrap();
        for i in 0..3 {
            m.on_segment(&info.session_id, &seg(i, true, "x")).unwrap();
        }

        let aborted = m.abort().unwrap();
        assert_eq!(m.phase(), Phase::Error);
        assert_eq!(aborted.session_id, info.session_id);

        let v = read_json(&info.dir.join("transcript.json"));
        assert_eq!(v["segments"].as_array().unwrap().len(), 3);
        // no session.json — the session never finished
        assert!(!info.dir.join("session.json").exists());

        // abort with nothing active is a no-op from Idle
        let mut idle = SessionMachine::new("0.1.0");
        assert!(idle.abort().is_none());
        assert_eq!(idle.phase(), Phase::Idle);
    }

    #[test]
    fn wall_clock_duration_used_when_audio_missing() {
        let root = tempfile::tempdir().unwrap();
        let mut m = SessionMachine::new("0.1.0");
        let info = m
            .begin_starting(root.path(), mic(), "nemotron-streaming-ml", "en")
            .unwrap();
        m.mark_recording(0).unwrap();
        m.begin_stopping().unwrap();
        let done = m.finalize(&[], Utc::now()).unwrap();
        assert!(done.duration_s >= 0.0);
        let v = read_json(&info.dir.join("session.json"));
        assert!(v["audio"].as_array().unwrap().is_empty());
        // system device falls back to 48 kHz
        assert_eq!(v["devices"]["system"]["sample_rate"], 48_000);
    }
}
