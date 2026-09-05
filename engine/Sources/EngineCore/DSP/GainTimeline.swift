import Foundation

/// Thread-safe ring of suppression gains on a session-time axis.
///
/// The echo analyzer produces one gain per 16 ms analysis frame from the
/// resampled 16 kHz streams; the mic delay line consumes them at the mic's
/// native rate. This decouples the two: the producer appends frames as the
/// `them` reference arrives, the consumer interpolates at arbitrary sample
/// times once `readyThrough` has passed.
///
/// Boundary behaviour is deliberately conservative — unity (no suppression)
/// before the first frame, hold-last past the watermark. A stalled analyzer
/// therefore degrades to "stop suppressing", never to "mute the user".
public final class GainTimeline: @unchecked Sendable {
    private var times: [Double]
    private var gains: [Float]
    private var head = 0        // index of oldest frame
    private var count = 0
    private let lock = NSLock()

    /// 4096 frames ≈ 65 s at the 16 ms analysis hop — a few tens of KB.
    public init(capacityFrames: Int = 4096) {
        precondition(capacityFrames > 1)
        times = [Double](repeating: 0, count: capacityFrames)
        gains = [Float](repeating: 1, count: capacityFrames)
    }

    public var capacity: Int { times.count }

    /// Session time of the most recently appended frame, or nil if empty.
    /// The delay line uses this to decide when a queued buffer may flush.
    public var readyThrough: Double? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return nil }
        return times[(head + count - 1) % times.count]
    }

    public var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Appends one frame. `frameTime` must be non-decreasing; an out-of-order
    /// frame is dropped rather than corrupting the search invariant.
    public func append(gain: Float, frameTime: Double) {
        lock.lock(); defer { lock.unlock() }
        let cap = times.count
        if count > 0 {
            let last = times[(head + count - 1) % cap]
            guard frameTime >= last else { return }
        }
        let tail = (head + count) % cap
        times[tail] = frameTime
        gains[tail] = gain
        if count == cap {
            head = (head + 1) % cap    // overwrite oldest
        } else {
            count += 1
        }
    }

    /// Linearly interpolated gain at a session time.
    /// Returns exactly 1.0 before the first frame; holds the last gain after
    /// the final one. Both are unity-safe defaults (see type doc).
    public func gain(atSessionTime t: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return 1.0 }
        let cap = times.count

        @inline(__always) func time(_ i: Int) -> Double { times[(head + i) % cap] }
        @inline(__always) func gainAt(_ i: Int) -> Float { gains[(head + i) % cap] }

        if t < time(0) { return 1.0 }
        if t >= time(count - 1) { return gainAt(count - 1) }

        // Binary search for the last frame with time <= t.
        var lo = 0, hi = count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if time(mid) <= t { lo = mid } else { hi = mid }
        }
        let t0 = time(lo), t1 = time(hi)
        let g0 = gainAt(lo), g1 = gainAt(hi)
        let span = t1 - t0
        guard span > 0 else { return g1 }
        let frac = Float((t - t0) / span)
        return g0 + (g1 - g0) * frac
    }
}
