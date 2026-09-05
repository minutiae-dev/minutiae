//! Small cross-cutting helpers.

pub mod clock;

/// Write a human-readable diagnostic line to **stderr**. stdout is reserved
/// for NDJSON protocol traffic, so all logging must go here (mirrors the Swift
/// engine's `log`).
pub fn log(message: &str) {
    eprintln!("[minutiae-engine] {message}");
}
