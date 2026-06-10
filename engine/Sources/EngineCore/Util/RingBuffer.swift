import Foundation

/// Thread-safe Float32 ring buffer for the ASR feed. Lock-based — at 16 kHz
/// mono the rates are trivial. Producer calls `append`; the consumer
/// (WindowedTranscriber) calls `popWindow(count:advance:)` which returns the
/// oldest `count` samples and discards the oldest `advance` samples, enabling
/// overlapping windows (e.g. 5 s window / 4 s advance = 1 s overlap).
public final class RingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private var head = 0        // index of oldest sample
    private var count = 0       // number of valid samples
    private var dropped = 0     // total samples lost to overflow
    private let lock = NSLock()

    public init(capacity: Int) {
        precondition(capacity > 0)
        storage = [Float](repeating: 0, count: capacity)
    }

    public var capacity: Int { storage.count }

    public var availableSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Total samples lost to overflow (consumer too slow). Used for dropped_windows stats.
    public var droppedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    public func append(_ samples: [Float]) {
        append(samples, count: samples.count)
    }

    public func append(_ samples: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let cap = storage.count
        if n >= cap {
            // Only the most recent `cap` samples survive.
            dropped += count + n - cap
            storage.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: samples + (n - cap), count: cap)
            }
            head = 0
            count = cap
            return
        }
        var tail = (head + count) % cap
        var remaining = n
        var src = samples
        // Overwrite-oldest if full.
        let overflow = (count + n) - cap
        if overflow > 0 {
            dropped += overflow
            head = (head + overflow) % cap
            count -= overflow
        }
        while remaining > 0 {
            let chunk = min(remaining, cap - tail)
            storage.withUnsafeMutableBufferPointer { dst in
                (dst.baseAddress! + tail).update(from: src, count: chunk)
            }
            tail = (tail + chunk) % cap
            src += chunk
            remaining -= chunk
        }
        count += n
    }

    private func append(_ samples: [Float], count n: Int) {
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            append(base, count: n)
        }
    }

    /// Returns the oldest `count` samples without removing them all: the read
    /// position advances by `advance` samples (advance ≤ count keeps overlap).
    /// Returns nil if fewer than `count` samples are buffered.
    public func popWindow(count windowCount: Int, advance: Int) -> [Float]? {
        precondition(advance >= 0 && advance <= windowCount)
        lock.lock(); defer { lock.unlock() }
        guard count >= windowCount else { return nil }
        var out = [Float](repeating: 0, count: windowCount)
        let cap = storage.count
        out.withUnsafeMutableBufferPointer { dst in
            var idx = head
            var remaining = windowCount
            var written = 0
            while remaining > 0 {
                let chunk = min(remaining, cap - idx)
                storage.withUnsafeBufferPointer { src in
                    (dst.baseAddress! + written).update(from: src.baseAddress! + idx, count: chunk)
                }
                idx = (idx + chunk) % cap
                written += chunk
                remaining -= chunk
            }
        }
        head = (head + advance) % cap
        count -= advance
        return out
    }

    /// Drains everything remaining (for the final partial window on stop).
    public func drainAll() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var out = [Float](repeating: 0, count: count)
        let cap = storage.count
        out.withUnsafeMutableBufferPointer { dst in
            var idx = head
            var remaining = count
            var written = 0
            while remaining > 0 {
                let chunk = min(remaining, cap - idx)
                storage.withUnsafeBufferPointer { src in
                    (dst.baseAddress! + written).update(from: src.baseAddress! + idx, count: chunk)
                }
                idx = (idx + chunk) % cap
                written += chunk
                remaining -= chunk
            }
        }
        head = 0
        count = 0
        return out
    }
}
