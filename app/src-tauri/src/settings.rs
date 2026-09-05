//! Persisted app settings — plain JSON at
//! `~/Library/Application Support/Minutiae/settings.json` (schema_version 1).
//!
//! Like sessions, the file on disk is authoritative and rebuildable: a missing
//! or corrupt file falls back to defaults rather than erroring. The only M2
//! setting is the vault folder — where the enhancement step writes `<Title>.md`.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

pub const SETTINGS_SCHEMA_VERSION: u32 = 1;

/// Default on-device ASR model id — mirrors the engine's default (Parakeet TDT
/// v3). Kept in sync with `ParakeetEngine.engineId` on the Swift side and the
/// wire `engine` id.
pub const DEFAULT_ASR_MODEL: &str = "parakeet-tdt-v3";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    /// Absolute path to the user's notes vault (Obsidian-compatible folder where
    /// enhanced Markdown is written). `None` until the user picks one.
    #[serde(default)]
    pub vault_dir: Option<String>,
    /// When true, enhancement runs in thinking mode (the model reasons before
    /// answering). Default false = instruct mode (straight to the answer).
    #[serde(default)]
    pub thinking_mode: bool,
    /// Selected ASR model id (hidden setting). One of `"parakeet-tdt-v3"`
    /// (default), `"nemotron-streaming-ml"` or `"nemotron-streaming-en"`.
    #[serde(default = "default_asr_model")]
    pub asr_model: String,
}

fn default_schema_version() -> u32 {
    SETTINGS_SCHEMA_VERSION
}

fn default_asr_model() -> String {
    DEFAULT_ASR_MODEL.to_string()
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            schema_version: SETTINGS_SCHEMA_VERSION,
            vault_dir: None,
            thinking_mode: false,
            asr_model: default_asr_model(),
        }
    }
}

/// Thread-safe, disk-backed settings handle managed by Tauri.
pub struct SettingsState {
    path: PathBuf,
    inner: Mutex<Settings>,
}

impl SettingsState {
    /// Load from `path`, or fall back to defaults if it is missing/corrupt.
    pub fn load(path: PathBuf) -> Self {
        let settings = std::fs::read(&path)
            .ok()
            .and_then(|bytes| match serde_json::from_slice::<Settings>(&bytes) {
                Ok(s) => Some(s),
                Err(e) => {
                    tracing::warn!("settings.json unreadable ({e}); using defaults");
                    None
                }
            })
            .unwrap_or_default();
        Self {
            path,
            inner: Mutex::new(settings),
        }
    }

    pub fn get(&self) -> Settings {
        self.inner.lock().unwrap().clone()
    }

    /// Set (or clear) the vault folder and persist atomically.
    pub fn set_vault_dir(&self, dir: Option<String>) -> io::Result<Settings> {
        let snapshot = {
            let mut g = self.inner.lock().unwrap();
            g.vault_dir = dir;
            g.schema_version = SETTINGS_SCHEMA_VERSION;
            g.clone()
        };
        let bytes = serde_json::to_vec_pretty(&snapshot)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        write_atomic(&self.path, &bytes)?;
        Ok(snapshot)
    }

    /// Toggle thinking mode and persist atomically.
    pub fn set_thinking_mode(&self, on: bool) -> io::Result<Settings> {
        let snapshot = {
            let mut g = self.inner.lock().unwrap();
            g.thinking_mode = on;
            g.schema_version = SETTINGS_SCHEMA_VERSION;
            g.clone()
        };
        let bytes = serde_json::to_vec_pretty(&snapshot)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        write_atomic(&self.path, &bytes)?;
        Ok(snapshot)
    }

    /// Set the selected ASR model id and persist atomically.
    pub fn set_asr_model(&self, model: String) -> io::Result<Settings> {
        let snapshot = {
            let mut g = self.inner.lock().unwrap();
            g.asr_model = model;
            g.schema_version = SETTINGS_SCHEMA_VERSION;
            g.clone()
        };
        let bytes = serde_json::to_vec_pretty(&snapshot)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        write_atomic(&self.path, &bytes)?;
        Ok(snapshot)
    }
}

/// Write-temp-then-rename, creating parent dirs, so readers never observe a
/// torn file. Shared with the scratchpad writer in `sidecar.rs`.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file_name = path
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_else(|| "out".into());
    let tmp = path.with_file_name(format!("{file_name}.tmp"));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_yields_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let s = SettingsState::load(dir.path().join("settings.json"));
        assert_eq!(s.get(), Settings::default());
        assert!(s.get().vault_dir.is_none());
    }

    #[test]
    fn set_persists_and_reloads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("settings.json");
        let s = SettingsState::load(path.clone());
        let saved = s.set_vault_dir(Some("/Users/u/Vault".into())).unwrap();
        assert_eq!(saved.vault_dir.as_deref(), Some("/Users/u/Vault"));
        assert_eq!(saved.schema_version, 1);
        assert!(!path.with_file_name("settings.json.tmp").exists());

        // A fresh load sees the persisted value.
        let reloaded = SettingsState::load(path);
        assert_eq!(reloaded.get().vault_dir.as_deref(), Some("/Users/u/Vault"));
    }

    #[test]
    fn corrupt_file_falls_back_to_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, b"{ this is not json ").unwrap();
        let s = SettingsState::load(path);
        assert_eq!(s.get(), Settings::default());
    }

    #[test]
    fn old_file_without_schema_version_loads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, br#"{"vault_dir":"/v"}"#).unwrap();
        let s = SettingsState::load(path);
        assert_eq!(s.get().schema_version, SETTINGS_SCHEMA_VERSION);
        assert_eq!(s.get().vault_dir.as_deref(), Some("/v"));
        // A file predating the asr_model field defaults to the multilingual model.
        assert_eq!(s.get().asr_model, DEFAULT_ASR_MODEL);
    }

    #[test]
    fn set_asr_model_persists_and_reloads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let s = SettingsState::load(path.clone());
        assert_eq!(s.get().asr_model, DEFAULT_ASR_MODEL);
        let saved = s.set_asr_model("nemotron-streaming-en".into()).unwrap();
        assert_eq!(saved.asr_model, "nemotron-streaming-en");
        let reloaded = SettingsState::load(path);
        assert_eq!(reloaded.get().asr_model, "nemotron-streaming-en");
    }
}
