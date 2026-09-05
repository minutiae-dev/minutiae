import Accelerate
import AVFoundation
import Foundation

/// Lookahead delay line for the `me` (mic) path.
///
/// The suppression gain for time *t* depends on the `them` reference around
/// *t*, which may not have been delivered yet when the mic buffer for *t*
/// arrives. So mic buffers are held briefly, then emitted scaled by the
/// interpolated gain envelope. Both the disk writer and the ASR feed consume
/// the emitted (gained) buffer, so the recording and the transcript agree.
///
/// CRITICAL: buffers handed to an `AVAudioEngine` tap callback are only valid
/// *during* that callback — the engine reuses their storage. Every buffer is
/// therefore deep-copied on enqueue. Holding the original would be a
/// use-after-free that manifests as intermittent garbage audio.
public final class DelayedMicPipeline: @unchecked Sendable {
    public typealias Emit = (AVAudioPCMBuffer, _ startTime: Double) -> Void

    /// Gain is sampled once per sub-block and linearly ramped across it: cheap,
    /// and no per-sample stair-stepping at gain transitions.
    static let rampBlockFrames = 64

    private let timeline: GainTimeline
    private let lookahead: Double
    private let format: AVAudioFormat
    private var queue: [(buffer: AVAudioPCMBuffer, t0: Double)] = []
    private let lock = NSLock()
    /// Serializes flushing. Flushes are driven from two threads — the mic
    /// callback and the levels timer — and the emit callback resamples through
    /// a stateful AVAudioConverter and appends to the transcriber. Without this
    /// the two could run concurrently and emit buffers out of order.
    /// Lock order is always flushLock → lock; never the reverse.
    private let flushLock = NSLock()

    public init(timeline: GainTimeline, format: AVAudioFormat, lookaheadSeconds: Double = 0.4) {
        self.timeline = timeline
        self.format = format
        self.lookahead = lookaheadSeconds
    }

    public var queuedBuffers: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    /// Deep-copies `buffer` and queues it. `t0` is the session-relative time of
    /// its first frame.
    public func enqueue(_ buffer: AVAudioPCMBuffer, t0: Double) {
        guard let copy = Self.copy(buffer) else { return }
        lock.lock(); defer { lock.unlock() }
        queue.append((copy, t0))
    }

    /// Emits every queued buffer whose span is fully resolved.
    ///
    /// A buffer is released when the analyzer has produced gains past its end
    /// **or** the lookahead deadline has passed — whichever comes first. The
    /// deadline is what bounds memory and latency: if the analyzer ever stalls
    /// (e.g. the `them` source stops delivering), buffers still drain, just at
    /// hold-last/unity gain rather than accumulating forever.
    public func flushReady(now: Double, emit: Emit) {
        let ready = timeline.readyThrough ?? -.infinity
        let deadline = max(ready, now - lookahead)
        flush(upTo: deadline, emit: emit)
    }

    /// Flushes everything unconditionally. Call at session stop, BEFORE
    /// finalizing writers or finishing transcribers, or the last `lookahead`
    /// seconds of mic audio are silently lost.
    public func drainAll(emit: Emit) {
        flush(upTo: .infinity, emit: emit)
    }

    private func flush(upTo deadline: Double, emit: Emit) {
        flushLock.lock(); defer { flushLock.unlock() }
        while true {
            lock.lock()
            guard let head = queue.first else { lock.unlock(); return }
            let frames = Int(head.buffer.frameLength)
            let end = head.t0 + Double(frames) / head.buffer.format.sampleRate
            guard end <= deadline else { lock.unlock(); return }
            queue.removeFirst()
            lock.unlock()

            applyGain(to: head.buffer, t0: head.t0)
            emit(head.buffer, head.t0)
        }
    }

    /// Scales a buffer in place by the interpolated gain envelope.
    private func applyGain(to buffer: AVAudioPCMBuffer, t0: Double) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let sr = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved

        var block = 0
        var gStart = gain(at: t0)
        while block < frames {
            let n = min(Self.rampBlockFrames, frames - block)
            let gEnd = gain(at: t0 + Double(block + n) / sr)
            var step = (gEnd - gStart) / Float(n)
            // vDSP_vrampmul multiplies in place by a linear ramp and advances
            // its start value; run it once per channel (strided when the
            // buffer is interleaved) from the same ramp origin.
            if interleaved {
                let ptr = data[0]
                for c in 0..<channels {
                    var g = gStart
                    vDSP_vrampmul(ptr + block * channels + c, vDSP_Stride(channels),
                                  &g, &step,
                                  ptr + block * channels + c, vDSP_Stride(channels),
                                  vDSP_Length(n))
                }
            } else {
                for c in 0..<channels {
                    var g = gStart
                    let ptr = data[c] + block
                    vDSP_vrampmul(ptr, 1, &g, &step, ptr, 1, vDSP_Length(n))
                }
            }
            gStart = gEnd
            block += n
        }
    }

    private func gain(at t: Double) -> Float {
        timeline.gain(atSessionTime: t)
    }

    /// Deep copy — tap buffers are only valid during their callback.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let src = buffer.floatChannelData,
              let dst = out.floatChannelData
        else { return nil }
        out.frameLength = frames
        let channels = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            dst[0].update(from: src[0], count: Int(frames) * channels)
        } else {
            for c in 0..<channels {
                dst[c].update(from: src[c], count: Int(frames))
            }
        }
        return out
    }
}
