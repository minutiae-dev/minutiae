//! Tauri commands invoked by the frontend (`app/src/lib/ipc.ts`).

use std::path::Path;

use tauri::State;

use crate::events::{AppStateSnapshot, SessionStatePayload};
use crate::history::{self, SessionDetail, SessionSummary};
use crate::llm::{LlmError, LlmManager};
use crate::settings::{Settings, SettingsState};
use crate::sidecar::SidecarManager;

#[tauri::command]
pub async fn list_devices(
    manager: State<'_, SidecarManager>,
) -> Result<crate::sidecar::DeviceList, String> {
    manager.list_devices().await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn start_session(
    mic_uid: String,
    them_source: Option<String>,
    manager: State<'_, SidecarManager>,
) -> Result<SessionStatePayload, String> {
    manager
        .start_session(mic_uid, them_source.unwrap_or_else(|| "system".into()))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn stop_session(
    manager: State<'_, SidecarManager>,
    settings: State<'_, SettingsState>,
) -> Result<SessionStatePayload, String> {
    let payload = manager.stop_session().await.map_err(|e| e.to_string())?;
    // Drop a readable transcript `.md` into the vault so every finished meeting
    // is browsable there — not just the ones the user later enhances. Best-effort:
    // a missing vault or empty transcript is a silent no-op, never a stop failure.
    if let (Some(dir), Some(vault)) = (manager.focused_session_dir(), settings.get().vault_dir) {
        if let Err(e) = crate::llm::write_transcript_note(Path::new(&vault), &dir) {
            tracing::warn!("transcript export on stop failed: {e}");
        }
    }
    Ok(payload)
}

/// Retry the launch-time model download after a failure. The download is
/// kicked off automatically at startup; this backs a UI "Retry" button.
#[tauri::command]
pub async fn prepare_models(
    manager: State<'_, SidecarManager>,
) -> Result<(), String> {
    manager
        .retry_prepare_models()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_state(manager: State<'_, SidecarManager>) -> AppStateSnapshot {
    manager.snapshot()
}

// -- Settings ---------------------------------------------------------------

#[tauri::command]
pub fn get_settings(settings: State<'_, SettingsState>) -> Settings {
    settings.get()
}

/// Persist the user's vault folder (where enhanced Markdown is written).
/// Validates that the path is an existing directory before saving.
#[tauri::command]
pub fn set_vault_dir(
    dir: String,
    settings: State<'_, SettingsState>,
) -> Result<Settings, String> {
    if !Path::new(&dir).is_dir() {
        return Err(format!("Not a folder: {dir}"));
    }
    settings
        .set_vault_dir(Some(dir))
        .map_err(|e| e.to_string())
}

/// Toggle thinking mode for enhancement (persisted).
#[tauri::command]
pub fn set_thinking_mode(
    on: bool,
    settings: State<'_, SettingsState>,
) -> Result<Settings, String> {
    settings.set_thinking_mode(on).map_err(|e| e.to_string())
}

/// Select the on-device ASR model (hidden setting; persisted). Validates the id
/// against the known model variants so the sidecar always receives a real id.
#[tauri::command]
pub fn set_asr_model(
    model: String,
    settings: State<'_, SettingsState>,
) -> Result<Settings, String> {
    const KNOWN: [&str; 3] = [
        "parakeet-tdt-v3",
        "nemotron-streaming-ml",
        "nemotron-streaming-en",
    ];
    if !KNOWN.contains(&model.as_str()) {
        return Err(format!("Unknown ASR model: {model}"));
    }
    settings.set_asr_model(model).map_err(|e| e.to_string())
}

// -- Scratchpad -------------------------------------------------------------

#[tauri::command]
pub fn save_scratchpad(text: String, manager: State<'_, SidecarManager>) -> Result<(), String> {
    manager.save_scratchpad(&text).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn load_scratchpad(manager: State<'_, SidecarManager>) -> String {
    manager.load_scratchpad()
}

// -- History (Recents) ------------------------------------------------------

/// List past sessions for the Recents sidebar, newest first.
#[tauri::command]
pub fn list_sessions(
    manager: State<'_, SidecarManager>,
    settings: State<'_, SettingsState>,
) -> Result<Vec<SessionSummary>, String> {
    let root = manager.sessions_root().map_err(|e| e.to_string())?;
    let vault = settings.get().vault_dir.map(std::path::PathBuf::from);
    // An unreadable sessions folder surfaces as an error in the UI rather than
    // an empty list that reads as "no meetings yet".
    history::list_sessions(&root, vault.as_deref()).map_err(|e| e.to_string())
}

/// Open a past session: focus it (so its notes can be edited / re-enhanced) and
/// return its transcript, notes, and enhanced note (if any). Refused while a
/// recording is in flight.
#[tauri::command]
pub fn open_session(
    dir: String,
    manager: State<'_, SidecarManager>,
    settings: State<'_, SettingsState>,
) -> Result<SessionDetail, String> {
    let path = std::path::PathBuf::from(&dir);
    manager.focus_session(path.clone()).map_err(|e| e.to_string())?;
    let vault = settings.get().vault_dir.map(std::path::PathBuf::from);
    history::load_session(&path, vault.as_deref())
}

/// Delete a past session: remove its folder and the enhanced note it wrote to
/// the vault. Refused while a recording is in flight. In SaaS builds, also
/// tombstones the session in the cloud so a later pull won't resurrect it.
#[tauri::command]
pub fn delete_session(
    dir: String,
    app: tauri::AppHandle,
    manager: State<'_, SidecarManager>,
    settings: State<'_, SettingsState>,
) -> Result<(), String> {
    if !matches!(
        manager.snapshot().state,
        crate::session::Phase::Idle | crate::session::Phase::Error
    ) {
        return Err("Stop the current recording before deleting a meeting.".into());
    }
    let root = manager.sessions_root().map_err(|e| e.to_string())?;
    let path = std::path::PathBuf::from(&dir);

    // SaaS-only: capture the id before the folder is gone, then tombstone.
    #[cfg(feature = "saas")]
    let session_id = crate::llm::SessionMeta::read(&path)
        .ok()
        .and_then(|m| m.session_id)
        .filter(|s| !s.is_empty());

    let vault = settings.get().vault_dir.map(std::path::PathBuf::from);
    #[cfg(feature = "saas")]
    if let Some(id) = &session_id {
        if path.canonicalize().map_err(|e| e.to_string())?.parent() != Some(root.canonicalize().map_err(|e| e.to_string())?.as_path()) {
            return Err("session must be inside the sessions directory".into());
        }
        crate::saas::sync::queue_delete(&app, &path, id)?;
    }
    history::delete_session(&root, &path, vault.as_deref())?;

    // `app` is only read in SaaS builds; silence the warning in OSS builds.
    let _ = &app;
    Ok(())
}

/// Reveal a session's transcript Markdown in Finder, exporting it to the vault
/// first if it isn't there yet (the note is only written on stop/enhance, and a
/// session pulled from another machine may never have had one written here).
#[tauri::command]
pub fn reveal_transcript_note(
    dir: String,
    manager: State<'_, SidecarManager>,
    settings: State<'_, SettingsState>,
) -> Result<(), String> {
    let root = manager.sessions_root().map_err(|e| e.to_string())?;
    let path = std::path::PathBuf::from(&dir);

    // Same containment rule as delete_session: only an immediate child of the
    // sessions root, so a stray path can't point this at arbitrary files.
    let canon_root = root.canonicalize().map_err(|e| e.to_string())?;
    let canon_dir = path.canonicalize().map_err(|e| e.to_string())?;
    if canon_dir.parent() != Some(canon_root.as_path()) {
        return Err("refusing to reveal a folder outside the sessions directory".into());
    }

    let vault = settings
        .get()
        .vault_dir
        .ok_or("Choose a vault folder first — that's where the Markdown is written.")?;
    let vault = Path::new(&vault);

    let note = match crate::llm::transcript_note_path(vault, &canon_dir) {
        Some(existing) => existing,
        None => crate::llm::write_transcript_note(vault, &canon_dir)
            .map_err(|e| e.to_string())?
            .ok_or("This meeting has no transcript to export yet.")?,
    };
    reveal_in_finder(&note)
}

/// `open -R` selects the file in a Finder window, which is what "show me where
/// this lives" means — plain `open` would launch it in a Markdown editor.
/// Arguments are passed directly to the process, never through a shell.
fn reveal_in_finder(path: &Path) -> Result<(), String> {
    let status = std::process::Command::new("open")
        .arg("-R")
        .arg(path)
        .status()
        .map_err(|e| format!("could not open Finder: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("Finder could not reveal {}", path.display()))
    }
}

// -- Enhancement (M2) -------------------------------------------------------

/// Enhance the focused session into a Markdown note in the vault. Streams
/// `llm:progress`/`llm:token` events while running and emits `llm:done` (or
/// `llm:error`) at the end; returns the written file path.
#[tauri::command]
pub async fn enhance_session(
    manager: State<'_, SidecarManager>,
    llm: State<'_, LlmManager>,
    settings: State<'_, SettingsState>,
) -> Result<String, String> {
    let session_dir = manager
        .focused_session_dir()
        .ok_or_else(|| "There is no finished session to enhance yet.".to_string())?;
    let snapshot = settings.get();
    let vault_dir = snapshot
        .vault_dir
        .ok_or_else(|| "Choose a vault folder first.".to_string())?;

    match llm
        .enhance(
            session_dir,
            std::path::PathBuf::from(vault_dir),
            snapshot.thinking_mode,
        )
        .await
    {
        Ok(doc) => Ok(doc.path.to_string_lossy().into_owned()),
        // Cancellation is a user action, not a failure: resolve silently with
        // no path so the UI just returns to idle.
        Err(LlmError::Cancelled) => Ok(String::new()),
        Err(e) => {
            let message = e.to_string();
            llm.emit_error(&message);
            Err(message)
        }
    }
}

#[tauri::command]
pub async fn cancel_enhance(llm: State<'_, LlmManager>) -> Result<(), String> {
    llm.cancel().await.map_err(|e| e.to_string())
}

/// Whether the enhancement model is downloaded (on disk) and/or loaded.
#[tauri::command]
pub fn get_llm_status(llm: State<'_, LlmManager>) -> crate::events::LlmStatusPayload {
    llm.status()
}

/// Download (if needed) and load the enhancement model on demand, streaming
/// `llm:model_progress` and finishing with `llm:model_ready`.
#[tauri::command]
pub async fn prepare_llm(llm: State<'_, LlmManager>) -> Result<(), String> {
    llm.prepare_model().await.map_err(|e| e.to_string())
}
