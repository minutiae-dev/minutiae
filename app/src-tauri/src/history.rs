//! Reading past sessions for the Recents sidebar.
//!
//! Plain files on disk stay authoritative (CLAUDE.md): we read
//! `<sessions_root>/<ts>--<ulid>/session.json` + `transcript.json` +
//! `scratchpad.md` directly, and look up a session's enhanced note by scanning
//! the vault for the `session_id` it stamped into the Markdown frontmatter.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::llm::SessionMeta;
use crate::protocol::Segment;

/// One row in the Recents list.
#[derive(Debug, Serialize)]
pub struct SessionSummary {
    pub session_id: String,
    pub dir: String,
    pub title: String,
    pub started_at: Option<String>,
    pub duration_s: Option<f64>,
    /// True if an enhanced note for this session exists in the vault.
    pub has_enhanced: bool,
}

/// Everything the UI needs to display a selected session.
#[derive(Debug, Serialize)]
pub struct SessionDetail {
    pub session_id: String,
    pub dir: String,
    pub title: String,
    pub started_at: Option<String>,
    pub duration_s: Option<f64>,
    pub segments: Vec<Segment>,
    pub scratchpad: String,
    /// The enhanced note's body (frontmatter stripped), if one exists.
    pub enhanced_markdown: Option<String>,
    /// Bare file name of that note in the vault.
    pub enhanced_file: Option<String>,
}

/// List finished sessions, newest first.
///
/// Errors instead of returning an empty list when the root is unreadable: an
/// empty Recents pane is indistinguishable from "no meetings", which is exactly
/// how a broken read presented itself before. A *missing* root is the normal
/// pre-first-capture state and yields `Ok(vec![])`.
///
/// Folders whose `session.json` is absent (aborted before finalize) or corrupt
/// are skipped, loudly enough to find in the log.
///
/// Sessions are **deduplicated by `session_id`**: one meeting can occupy two
/// folders when a pull wrote a differently-named folder beside the recording
/// (see [`rank`] for which copy wins). Callers therefore get one row per
/// meeting, and the sync push loop — which iterates this list — can never push
/// a recovered stub over the real session.
pub fn list_sessions(root: &Path, vault_dir: Option<&Path>) -> std::io::Result<Vec<SessionSummary>> {
    let enhanced = vault_dir.map(enhanced_index).unwrap_or_default();
    list_sessions_indexed(root, &enhanced)
}

pub(crate) fn list_sessions_indexed(root: &Path, enhanced: &HashMap<String, PathBuf>) -> std::io::Result<Vec<SessionSummary>> {
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        // No sessions folder yet — a fresh install, not a failure.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => {
            return Err(std::io::Error::new(
                e.kind(),
                format!("cannot read the sessions folder {}: {e}", root.display()),
            ))
        }
    };

    let mut scanned = 0usize;
    let mut skipped = 0usize;
    // session_id → index into `out`, for the dedupe below. Folders whose
    // `session.json` carries no id can't be matched up, so they are never
    // deduplicated (dropping one would risk dropping the only copy).
    let mut by_id: HashMap<String, usize> = HashMap::new();
    let mut out: Vec<SessionSummary> = Vec::new();
    let mut ranks: Vec<Rank> = Vec::new();

    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        scanned += 1;
        let meta = match SessionMeta::read(&dir) {
            Ok(meta) => meta,
            // Never captured anything / not finalized: ordinary, and already
            // handled by `recover_orphaned_sessions` when there is a transcript.
            Err(crate::llm::LlmError::NoSession) => {
                skipped += 1;
                tracing::debug!(dir = %dir.display(), "no session.json — skipping");
                continue;
            }
            // Corrupt or unreadable: this one *is* a lost meeting, so say so.
            Err(e) => {
                skipped += 1;
                tracing::warn!(dir = %dir.display(), error = %e, "unreadable session.json — skipping");
                continue;
            }
        };

        let session_id = meta.session_id.clone().unwrap_or_default();
        let summary = SessionSummary {
            has_enhanced: !session_id.is_empty() && (enhanced.contains_key(&session_id) || dir.join("enhanced.md").is_file()),
            session_id: session_id.clone(),
            dir: dir.to_string_lossy().into_owned(),
            title: meta.title(),
            started_at: meta.started_at.clone(),
            duration_s: meta.duration_s,
        };
        let rank = rank(&dir, &meta);

        match by_id.get(&session_id).copied().filter(|_| !session_id.is_empty()) {
            Some(idx) if rank <= ranks[idx] => {
                tracing::debug!(dir = %dir.display(), "duplicate session folder — hiding the weaker copy");
            }
            Some(idx) => {
                tracing::debug!(dir = %dir.display(), replaced = %out[idx].dir, "duplicate session folder — preferring this copy");
                out[idx] = summary;
                ranks[idx] = rank;
            }
            None => {
                if !session_id.is_empty() {
                    by_id.insert(session_id, out.len());
                }
                out.push(summary);
                ranks.push(rank);
            }
        }
    }

    // Folder names are ISO timestamps, but sort by `started_at` for robustness.
    out.sort_by(|a, b| b.started_at.cmp(&a.started_at));
    tracing::info!(
        root = %root.display(),
        scanned,
        skipped,
        listed = out.len(),
        "listed sessions"
    );
    Ok(out)
}

/// How good a folder is as *the* copy of its session, best last. Ordered on
/// (a) a real finalize beats a `recovered` stub — the stub has no
/// engine/devices/audio and often no `started_at`; (b) the canonical
/// `<stamp>--<ulid>` name beats anything else — a July server build sent
/// `str(datetime)` names (`2026-06-12 00:04:41+00:00--<ulid>`) that a pull
/// materialized beside the real folders; (c) the more recently written
/// `session.json` wins the remaining ties.
type Rank = (bool, bool, Option<std::time::SystemTime>);

fn rank(dir: &Path, meta: &SessionMeta) -> Rank {
    let canonical = dir
        .file_name()
        .and_then(|n| n.to_str())
        .map(is_canonical_dir_name)
        .unwrap_or(false);
    let mtime = std::fs::metadata(dir.join("session.json"))
        .and_then(|m| m.modified())
        .ok();
    (!meta.recovered, canonical, mtime)
}

/// True for `2026-06-13T14-30-22Z--01J9XYZ…` — the name `session.rs` writes.
pub fn is_canonical_dir_name(name: &str) -> bool {
    let Some((stamp, id)) = name.rsplit_once("--") else {
        return false;
    };
    is_ulid(id) && is_folder_stamp(stamp)
}

/// `2026-06-13T14-30-22Z`, the filesystem-safe stamp from `session.rs`.
fn is_folder_stamp(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 20
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[13] == b'-'
        && b[16] == b'-'
        && b[19] == b'Z'
        && [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
            .iter()
            .all(|&i| b[i].is_ascii_digit())
}

/// Crockford base32, 26 chars — the ULID `session.rs` mints (excludes I, L, O, U).
pub fn is_ulid(s: &str) -> bool {
    s.len() == 26
        && s.bytes().all(|c| {
            c.is_ascii_digit()
                || (c.is_ascii_uppercase() && !matches!(c, b'I' | b'L' | b'O' | b'U'))
        })
}


/// Load a single session's transcript, notes, and (if any) enhanced note.
pub fn load_session(dir: &Path, vault_dir: Option<&Path>) -> Result<SessionDetail, String> {
    let enhanced = vault_dir.map(enhanced_index).unwrap_or_default();
    load_session_indexed(dir, &enhanced)
}

pub(crate) fn load_session_indexed(dir: &Path, enhanced: &HashMap<String, PathBuf>) -> Result<SessionDetail, String> {
    let meta = SessionMeta::read(dir).map_err(|e| e.to_string())?;
    let session_id = meta.session_id.clone().unwrap_or_default();
    let segments = read_segments(dir);
    let scratchpad = std::fs::read_to_string(dir.join("scratchpad.md")).unwrap_or_default();

    let (enhanced_markdown, enhanced_file) = enhanced.get(&session_id)
        .map(|path| {
            let body = std::fs::read_to_string(&path)
                .ok()
                .map(|s| strip_frontmatter(&s));
            let file = path
                .file_name()
                .map(|f| f.to_string_lossy().into_owned());
            (body, file)
        })
        .unwrap_or_else(|| (std::fs::read_to_string(dir.join("enhanced.md")).ok(), None));

    Ok(SessionDetail {
        dir: dir.to_string_lossy().into_owned(),
        title: meta.title(),
        started_at: meta.started_at,
        duration_s: meta.duration_s,
        segments,
        scratchpad,
        enhanced_markdown,
        enhanced_file,
        session_id,
    })
}

/// Delete a session: remove its folder, and (if a vault is set) the enhanced
/// note it produced. `dir` must live directly under `root` — anything else is
/// refused so a stray path can never delete outside the sessions tree.
pub fn delete_session(
    root: &Path,
    dir: &Path,
    vault_dir: Option<&Path>,
) -> Result<(), String> {
    // Path-safety: the target must be an immediate child of the sessions root.
    let canon_root = root.canonicalize().map_err(|e| e.to_string())?;
    let canon_dir = dir.canonicalize().map_err(|e| e.to_string())?;
    if canon_dir.parent() != Some(canon_root.as_path()) {
        return Err("refusing to delete a folder outside the sessions directory".into());
    }

    // Remove the matching enhanced note from the vault first (best-effort): if
    // the folder delete later fails we'd rather not leave an orphaned note, but
    // a missing note must never block deleting the session itself.
    if let Some(vault) = vault_dir {
        if let Ok(meta) = SessionMeta::read(&canon_dir) {
            if let Some(id) = meta.session_id.filter(|s| !s.is_empty()) {
                if let Some(note) = enhanced_index(vault).remove(&id) {
                    let _ = std::fs::remove_file(note);
                }
            }
        }
    }

    std::fs::remove_dir_all(&canon_dir).map_err(|e| e.to_string())
}

/// Recover a session folder that was never cleanly finalized (engine crash,
/// force-quit, unclean stop): it has a `transcript.json` but no `session.json`,
/// so it is invisible to `list_sessions` and can't be opened. Synthesize a
/// minimal `session.json` from the folder name + transcript so the recording is
/// not lost. Idempotent and cheap: a no-op if `session.json` already exists or
/// there is nothing captured to recover. Returns true if a file was written.
pub fn recover_session_dir(dir: &Path) -> bool {
    if !dir.is_dir() || dir.join("session.json").exists() {
        return false;
    }
    // Only recover folders that actually captured something.
    if !dir.join("transcript.json").is_file() {
        return false;
    }
    let Some(name) = dir.file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    // Folder name is `<ts>--<ulid>`, ts = `%Y-%m-%dT%H-%M-%SZ` (see session.rs).
    let (started_at, session_id) = match name.split_once("--") {
        Some((ts, id)) => (folder_ts_to_iso(ts), id.to_string()),
        None => (None, String::new()),
    };
    // Duration: the last segment's end time (best-effort; 0 if none).
    let duration_s = read_segments(dir)
        .iter()
        .map(|s| s.t1)
        .fold(0.0_f64, f64::max);

    let recovered = serde_json::json!({
        "schema_version": 1,
        "session_id": session_id,
        "started_at": started_at,
        "duration_s": duration_s,
        "title": serde_json::Value::Null,
        // Marks a crash-recovered session (clean finalize never wrote this file).
        "recovered": true,
    });
    let Ok(bytes) = serde_json::to_vec_pretty(&recovered) else {
        return false;
    };
    crate::settings::write_atomic(&dir.join("session.json"), &bytes).is_ok()
}

/// Sweep the sessions root and recover every orphaned folder (see
/// [`recover_session_dir`]). Returns the number recovered. Safe to run at
/// startup — it self-heals sessions left behind by a previous crash.
pub fn recover_orphaned_sessions(root: &Path) -> usize {
    let Ok(entries) = std::fs::read_dir(root) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|e| recover_session_dir(&e.path()))
        .count()
}

/// `2026-06-13T14-30-22Z` (filesystem-safe folder stamp) → `2026-06-13T14:30:22Z`
/// (RFC3339), so the recovered title renders cleanly. Returns None if the shape
/// is unexpected.
fn folder_ts_to_iso(ts: &str) -> Option<String> {
    let (date, time) = ts.split_once('T')?;
    Some(format!("{date}T{}", time.replace('-', ":")))
}

#[derive(serde::Deserialize)]
struct TranscriptFile {
    #[serde(default)]
    segments: Vec<Segment>,
}

/// Read `transcript.json` into segments ordered by engine index ("" if absent).
fn read_segments(dir: &Path) -> Vec<Segment> {
    let path = dir.join("transcript.json");
    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    let mut file: TranscriptFile = match serde_json::from_slice(&bytes) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    file.segments.sort_by_key(|s| s.idx);
    file.segments
}

/// Map `session_id` → enhanced-note path by scanning the vault's `*.md`
/// frontmatter. On collisions (re-enhanced sessions write `-N` variants) keep
/// the most recently modified file.
pub(crate) fn enhanced_index(vault: &Path) -> HashMap<String, PathBuf> {
    let mut map: HashMap<String, PathBuf> = HashMap::new();
    let Ok(entries) = std::fs::read_dir(vault) else {
        return map;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let (id, kind) = read_note_meta(&path);
        let Some(id) = id else {
            continue;
        };
        // A raw-transcript export carries the same session_id but is not an
        // enhanced note — never let it stand in for one.
        if kind.as_deref() == Some("transcript") {
            continue;
        }
        match map.get(&id) {
            Some(existing) if !is_newer(&path, existing) => {}
            _ => {
                map.insert(id, path);
            }
        }
    }
    map
}

/// Path of this session's enhanced note in the vault, if it has one. Notes are
/// keyed by `session_id` frontmatter rather than filename, so a caller that only
/// knows the session id (e.g. cloud sync writing a pulled note) can still find
/// and update the existing file instead of creating a duplicate.
pub fn enhanced_note_path(vault: &Path, session_id: &str) -> Option<PathBuf> {
    if session_id.is_empty() {
        return None;
    }
    enhanced_index(vault).remove(session_id)
}

/// True if `a` was modified more recently than `b` (false if either is unknown).
fn is_newer(a: &Path, b: &Path) -> bool {
    let mtime = |p: &Path| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    match (mtime(a), mtime(b)) {
        (Some(ta), Some(tb)) => ta > tb,
        _ => false,
    }
}

/// Pull `session_id` out of a note's YAML frontmatter, if present.
fn read_session_id(path: &Path) -> Option<String> {
    read_note_meta(path).0
}

/// Read a note's `session_id` and `type` frontmatter fields in one pass.
fn read_note_meta(path: &Path) -> (Option<String>, Option<String>) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return (None, None);
    };
    let Some(rest) = text.strip_prefix("---\n") else {
        return (None, None);
    };
    let Some(end) = rest.find("\n---") else {
        return (None, None);
    };
    let mut session_id = None;
    let mut kind = None;
    for line in rest[..end].lines() {
        if let Some(v) = line.strip_prefix("session_id:") {
            session_id = Some(v.trim().trim_matches('"').to_string());
        } else if let Some(v) = line.strip_prefix("type:") {
            kind = Some(v.trim().trim_matches('"').to_string());
        }
    }
    (session_id, kind)
}

/// Drop a leading `---\n…\n---\n` YAML frontmatter block so the UI shows just
/// the note body (matching what live enhancement streams).
fn strip_frontmatter(markdown: &str) -> String {
    if let Some(rest) = markdown.strip_prefix("---\n") {
        if let Some(idx) = rest.find("\n---") {
            let after = &rest[idx + "\n---".len()..];
            return after.trim_start_matches(['\n', '-']).trim_start().to_string();
        }
    }
    markdown.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_frontmatter_removes_block() {
        let md = "---\ntitle: \"x\"\nsession_id: \"01ABC\"\n---\n\n# x\n\nBody";
        assert_eq!(strip_frontmatter(md), "# x\n\nBody");
        assert_eq!(strip_frontmatter("no frontmatter"), "no frontmatter");
    }

    #[test]
    fn read_session_id_parses_frontmatter() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("note.md");
        std::fs::write(&p, "---\ntitle: \"T\"\nsession_id: \"01XYZ\"\n---\n\nbody").unwrap();
        assert_eq!(read_session_id(&p).as_deref(), Some("01XYZ"));
    }

    #[test]
    fn delete_session_removes_folder_and_vault_note() {
        let root = tempfile::tempdir().unwrap();
        let vault = tempfile::tempdir().unwrap();
        let sess = root.path().join("2026-01-01--01ABC");
        std::fs::create_dir_all(&sess).unwrap();
        std::fs::write(
            sess.join("session.json"),
            "{\"schema_version\":1,\"session_id\":\"01ABC\"}",
        )
        .unwrap();
        let note = vault.path().join("Meeting.md");
        std::fs::write(&note, "---\nsession_id: \"01ABC\"\n---\n\nbody").unwrap();

        delete_session(root.path(), &sess, Some(vault.path())).unwrap();
        assert!(!sess.exists());
        assert!(!note.exists());
    }

    #[test]
    fn recover_session_backfills_orphan() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("2026-06-13T14-30-22Z--01ORPHAN");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("transcript.json"),
            r#"{"schema_version":1,"session_id":"01ORPHAN","segments":[
                {"idx":0,"channel":"me","t0":0.0,"t1":12.5,"text":"hi","confidence":-1,"final":true,"engine":"x"}
            ]}"#,
        )
        .unwrap();

        assert!(recover_session_dir(&dir));
        // Now visible to the Recents listing with a sane title + duration.
        let summaries = list_sessions(root.path(), None).unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].session_id, "01ORPHAN");
        assert_eq!(summaries[0].started_at.as_deref(), Some("2026-06-13T14:30:22Z"));
        assert_eq!(summaries[0].duration_s, Some(12.5));
        // Idempotent: a second pass writes nothing new.
        assert!(!recover_session_dir(&dir));
    }

    #[test]
    fn recover_skips_folders_without_transcript() {
        let root = tempfile::tempdir().unwrap();
        // Folder that never captured anything (e.g. failed at start).
        let empty = root.path().join("2026-06-13T14-30-22Z--01EMPTY");
        std::fs::create_dir_all(&empty).unwrap();
        // Folder that already finalized cleanly.
        let done = root.path().join("2026-06-13T15-00-00Z--01DONE");
        std::fs::create_dir_all(&done).unwrap();
        std::fs::write(done.join("session.json"), r#"{"schema_version":1,"session_id":"01DONE"}"#).unwrap();
        std::fs::write(done.join("transcript.json"), r#"{"segments":[]}"#).unwrap();

        assert_eq!(recover_orphaned_sessions(root.path()), 0);
        assert!(!empty.join("session.json").exists());
    }

    #[test]
    fn transcript_note_does_not_count_as_enhanced() {
        let root = tempfile::tempdir().unwrap();
        let vault = tempfile::tempdir().unwrap();
        let dir = root.path().join("2026-06-25T10-00-00Z--01ABC");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("session.json"),
            r#"{"schema_version":1,"session_id":"01ABC","started_at":"2026-06-25T10:00:00Z"}"#,
        )
        .unwrap();
        // A raw-transcript export carries the same session_id.
        std::fs::write(
            vault.path().join("meeting-transcript.md"),
            "---\nsession_id: \"01ABC\"\ntype: transcript\n---\n\nbody",
        )
        .unwrap();

        let s = list_sessions(root.path(), Some(vault.path())).unwrap();
        assert_eq!(s.len(), 1);
        assert!(!s[0].has_enhanced, "a transcript note must not mark a session enhanced");
    }

    /// Writes a session folder; `recovered` marks it as a synthesized stub.
    fn write_session(root: &Path, name: &str, id: &str, started: Option<&str>, recovered: bool) -> PathBuf {
        let dir = root.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        let json = serde_json::json!({
            "schema_version": 1,
            "session_id": id,
            "started_at": started,
            "duration_s": 1.0,
            "recovered": recovered,
        });
        std::fs::write(dir.join("session.json"), serde_json::to_vec_pretty(&json).unwrap()).unwrap();
        dir
    }

    /// The July pull bug left a `str(datetime)`-named stub beside every real
    /// recording. One meeting must show as one row — the real one.
    #[test]
    fn duplicate_stub_folder_is_hidden_behind_the_real_session() {
        let root = tempfile::tempdir().unwrap();
        let real = write_session(
            root.path(),
            "2026-06-12T00-04-41Z--01KTWJAAP04PAZ922CJ5C9548Z",
            "01KTWJAAP04PAZ922CJ5C9548Z",
            Some("2026-06-12T00:04:41Z"),
            false,
        );
        write_session(
            root.path(),
            "2026-06-12 00:04:41+00:00--01KTWJAAP04PAZ922CJ5C9548Z",
            "01KTWJAAP04PAZ922CJ5C9548Z",
            None,
            true,
        );

        let listed = list_sessions(root.path(), None).unwrap();
        assert_eq!(listed.len(), 1, "one meeting, one row");
        assert_eq!(listed[0].dir, real.to_string_lossy());
        assert_eq!(listed[0].started_at.as_deref(), Some("2026-06-12T00:04:41Z"));
    }

    /// …but a stub that is the *only* local copy must stay visible: hiding it
    /// would lose the meeting entirely.
    #[test]
    fn siblingless_stub_is_still_listed() {
        let root = tempfile::tempdir().unwrap();
        write_session(
            root.path(),
            "2026-07-01 09-00-00+00:00--01KVEST9K0AAAAAAAAAAAAAAAA",
            "01KVEST9K0AAAAAAAAAAAAAAAA",
            None,
            true,
        );
        assert_eq!(list_sessions(root.path(), None).unwrap().len(), 1);
    }

    /// Two real copies of one session: the canonically named folder wins.
    #[test]
    fn canonical_folder_name_breaks_the_tie() {
        let root = tempfile::tempdir().unwrap();
        write_session(root.path(), "odd-name--01KTWJAAP04PAZ922CJ5C9548Z", "01KTWJAAP04PAZ922CJ5C9548Z", Some("2026-06-12T00:04:41Z"), false);
        let canonical = write_session(
            root.path(),
            "2026-06-12T00-04-41Z--01KTWJAAP04PAZ922CJ5C9548Z",
            "01KTWJAAP04PAZ922CJ5C9548Z",
            Some("2026-06-12T00:04:41Z"),
            false,
        );
        let listed = list_sessions(root.path(), None).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].dir, canonical.to_string_lossy());
    }

    /// A missing root is "no meetings yet"; an unreadable one is an error the
    /// UI must show rather than an empty list that reads as "no meetings".
    #[test]
    fn missing_root_is_empty_but_unreadable_root_is_an_error() {
        let base = tempfile::tempdir().unwrap();
        assert!(list_sessions(&base.path().join("nope"), None).unwrap().is_empty());

        // A file where the sessions folder should be: read_dir fails with
        // NotADirectory, which must not masquerade as an empty list.
        let as_file = base.path().join("sessions");
        std::fs::write(&as_file, b"not a directory").unwrap();
        assert!(list_sessions(&as_file, None).is_err());
    }

    #[test]
    fn corrupt_session_json_is_skipped_not_fatal() {
        let root = tempfile::tempdir().unwrap();
        write_session(root.path(), "2026-06-12T00-04-41Z--01KTWJAAP04PAZ922CJ5C9548Z", "01KTWJAAP04PAZ922CJ5C9548Z", Some("2026-06-12T00:04:41Z"), false);
        let bad = root.path().join("2026-06-13T00-00-00Z--01KTWJAAP04PAZ922CJ5C9549Z");
        std::fs::create_dir_all(&bad).unwrap();
        std::fs::write(bad.join("session.json"), b"{ this is not json").unwrap();

        let listed = list_sessions(root.path(), None).unwrap();
        assert_eq!(listed.len(), 1, "the good session still lists");
    }

    #[test]
    fn canonical_dir_name_recognizes_the_real_format() {
        assert!(is_canonical_dir_name("2026-06-12T00-04-41Z--01KTWJAAP04PAZ922CJ5C9548Z"));
        // The malformed names a July server build produced.
        assert!(!is_canonical_dir_name("2026-06-12 00:04:41+00:00--01KTWJAAP04PAZ922CJ5C9548Z"));
        assert!(!is_canonical_dir_name("2026-06-12T00-04-41Z--short"));
        // ULIDs are Crockford base32: no I, L, O or U.
        assert!(!is_ulid("01KTWJAAP04PAZ922CJ5C9548I"));
    }

    #[test]
    fn delete_session_refuses_outside_root() {
        let root = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let stray = other.path().join("victim");
        std::fs::create_dir_all(&stray).unwrap();

        assert!(delete_session(root.path(), &stray, None).is_err());
        assert!(stray.exists());
    }
}
