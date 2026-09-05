//! Audio capture (WASAPI). Phase 1 implements device enumeration; the capture
//! sources, resampler, and ring buffer land in Phase 2.
//!
//! Everything platform-specific lives behind `#[cfg(windows)]` here so the
//! portable IPC core still builds and tests on the macOS dev host (where
//! `devices::list_input_devices` returns a mock).

pub mod devices;
