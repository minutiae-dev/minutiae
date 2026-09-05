//! Session timing anchor.
//!
//! Mirrors the Swift `SessionClock`: capture one wall-clock epoch (`t0_epoch_ms`,
//! sent in `session_started`) and one monotonic anchor at session start, so
//! every segment's `t0`/`t1` are session-relative seconds on a single timeline
//! shared by both channels — "me" and "them" can never drift apart.
//!
//! On Windows `std::time::Instant` is backed by `QueryPerformanceCounter`, so
//! this is the portable equivalent of the macOS mach-time anchor; WASAPI buffer
//! QPC timestamps convert into the same frame of reference in Phase 2.

use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct SessionClock {
    anchor: Instant,
    t0_epoch_ms: u64,
}

impl Default for SessionClock {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionClock {
    /// Anchor the clock to "now". Call once at session start.
    pub fn new() -> Self {
        let t0_epoch_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        Self {
            anchor: Instant::now(),
            t0_epoch_ms,
        }
    }

    /// Wall-clock epoch milliseconds at the anchor — the value reported in
    /// `session_started.t0_epoch_ms`.
    pub fn t0_epoch_ms(&self) -> u64 {
        self.t0_epoch_ms
    }

    /// Seconds elapsed since the anchor (monotonic, never negative).
    pub fn now_seconds(&self) -> f64 {
        self.anchor.elapsed().as_secs_f64()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_is_populated_and_monotonic() {
        let clock = SessionClock::new();
        // A plausible 2020s epoch (ms), i.e. clearly populated.
        assert!(clock.t0_epoch_ms() > 1_577_836_800_000);
        let a = clock.now_seconds();
        let b = clock.now_seconds();
        assert!(b >= a, "now_seconds must be monotonic non-decreasing");
        assert!(a >= 0.0);
    }
}
