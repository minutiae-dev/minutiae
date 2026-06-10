import Foundation

/// Anchors mach host time at session start so every audio buffer's
/// AudioTimeStamp.mHostTime converts to session-relative seconds. Both
/// channels stamp from the same host clock, so cross-channel alignment is
/// wall-clock-true and cannot drift.
public struct SessionClock: Sendable {
    public let anchorHostTime: UInt64
    public let t0EpochMs: Int64
    /// Seconds per host tick (timebase numer/denom / 1e9).
    private let secondsPerTick: Double

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.init(anchorHostTime: mach_absolute_time(),
                  t0EpochMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                  timebaseNumer: info.numer,
                  timebaseDenom: info.denom)
    }

    /// Injectable timebase for tests.
    public init(anchorHostTime: UInt64, t0EpochMs: Int64, timebaseNumer: UInt32, timebaseDenom: UInt32) {
        self.anchorHostTime = anchorHostTime
        self.t0EpochMs = t0EpochMs
        self.secondsPerTick = (Double(timebaseNumer) / Double(timebaseDenom)) / 1_000_000_000.0
    }

    /// Session-relative seconds for a mach host time. Times before the anchor
    /// return negative values (callers may clamp).
    public func seconds(fromHostTime hostTime: UInt64) -> Double {
        if hostTime >= anchorHostTime {
            return Double(hostTime - anchorHostTime) * secondsPerTick
        } else {
            return -Double(anchorHostTime - hostTime) * secondsPerTick
        }
    }

    /// Session-relative seconds for "now".
    public func now() -> Double {
        seconds(fromHostTime: mach_absolute_time())
    }
}
