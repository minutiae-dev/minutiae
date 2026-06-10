//! Tauri commands invoked by the frontend (`app/src/lib/ipc.ts`).

use tauri::State;

use crate::events::{AppStateSnapshot, SessionStatePayload};
use crate::protocol::DeviceInfo;
use crate::sidecar::SidecarManager;

#[tauri::command]
pub async fn list_devices(
    manager: State<'_, SidecarManager>,
) -> Result<Vec<DeviceInfo>, String> {
    manager.list_devices().await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn start_session(
    mic_uid: String,
    manager: State<'_, SidecarManager>,
) -> Result<SessionStatePayload, String> {
    manager
        .start_session(mic_uid)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn stop_session(
    manager: State<'_, SidecarManager>,
) -> Result<SessionStatePayload, String> {
    manager.stop_session().await.map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_state(manager: State<'_, SidecarManager>) -> AppStateSnapshot {
    manager.snapshot()
}
