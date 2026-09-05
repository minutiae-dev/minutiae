//! Input (capture) device enumeration → [`DeviceInfo`].
//!
//! On Windows this walks the WASAPI MMDevice capture endpoints. On any other
//! target (the macOS dev host) it returns a single mock device so the IPC seam
//! is exercisable end-to-end without WASAPI.

use crate::ipc::messages::DeviceInfo;

/// List active audio **input** endpoints, with the system default flagged.
pub fn list_input_devices() -> Result<Vec<DeviceInfo>, String> {
    #[cfg(windows)]
    {
        win::list_input_devices()
    }
    #[cfg(not(windows))]
    {
        Ok(vec![DeviceInfo {
            uid: "mock-default-input".into(),
            name: "Mock Input (non-Windows build)".into(),
            sample_rate: 48_000,
            is_default: true,
        }])
    }
}

// ---------------------------------------------------------------------------
// Windows / WASAPI implementation.
//
// NOTE: this module compiles only on a Windows target. It has not been built
// on the macOS dev host where the rest of the crate is tested; verify it with
// `cargo build --target x86_64-pc-windows-msvc` on a Windows machine (Phase 1
// smoke test).
#[cfg(windows)]
mod win {
    use crate::ipc::messages::DeviceInfo;
    use crate::util::log;

    use windows::core::PWSTR;
    use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
    use windows::Win32::Media::Audio::{
        eCapture, eConsole, IAudioClient, IMMDeviceEnumerator, MMDeviceEnumerator,
        DEVICE_STATE_ACTIVE,
    };
    use windows::Win32::System::Com::StructuredStorage::PropVariantToStringAlloc;
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED, STGM_READ,
    };

    /// Read a COM-allocated wide string into an owned `String` (best-effort).
    unsafe fn pwstr_to_string(p: PWSTR) -> String {
        if p.is_null() {
            return String::new();
        }
        p.to_string().unwrap_or_default()
    }

    pub fn list_input_devices() -> Result<Vec<DeviceInfo>, String> {
        unsafe {
            // COM may already be initialized on this thread; treat the
            // "already initialized" HRESULT as success.
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);

            let enumerator: IMMDeviceEnumerator =
                CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                    .map_err(|e| format!("CoCreateInstance(MMDeviceEnumerator): {e}"))?;

            // Default capture endpoint id, for the is_default flag. Absent
            // (no input device) is not an error — just means nothing default.
            let default_uid: Option<String> = enumerator
                .GetDefaultAudioEndpoint(eCapture, eConsole)
                .ok()
                .and_then(|d| d.GetId().ok())
                .map(|id| pwstr_to_string(id));

            let collection = enumerator
                .EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)
                .map_err(|e| format!("EnumAudioEndpoints(eCapture): {e}"))?;

            let count = collection
                .GetCount()
                .map_err(|e| format!("IMMDeviceCollection::GetCount: {e}"))?;

            let mut items = Vec::with_capacity(count as usize);
            for i in 0..count {
                let device = match collection.Item(i) {
                    Ok(d) => d,
                    Err(e) => {
                        log(&format!("skipping device {i}: Item failed: {e}"));
                        continue;
                    }
                };

                let uid = match device.GetId() {
                    Ok(id) => pwstr_to_string(id),
                    Err(e) => {
                        log(&format!("skipping device {i}: GetId failed: {e}"));
                        continue;
                    }
                };

                // Friendly name via the property store.
                let name = device
                    .OpenPropertyStore(STGM_READ)
                    .ok()
                    .and_then(|store| store.GetValue(&PKEY_Device_FriendlyName).ok())
                    .and_then(|prop| PropVariantToStringAlloc(&prop).ok())
                    .map(|p| pwstr_to_string(p))
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "Unknown input device".to_string());

                // Native mix-format sample rate (fall back to 48 kHz). We never
                // force a rate — the writer records this native rate; only the
                // ASR feed is resampled (Phase 2).
                let sample_rate = device
                    .Activate::<IAudioClient>(CLSCTX_ALL, None)
                    .ok()
                    .and_then(|client| client.GetMixFormat().ok())
                    .map(|fmt| (*fmt).nSamplesPerSec)
                    .unwrap_or(48_000);

                let is_default = default_uid.as_deref() == Some(uid.as_str());

                items.push(DeviceInfo {
                    uid,
                    name,
                    sample_rate,
                    is_default,
                });
            }

            Ok(items)
        }
    }
}
