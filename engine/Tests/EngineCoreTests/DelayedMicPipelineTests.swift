import AVFoundation
import XCTest
@testable import EngineCore

final class DelayedMicPipelineTests: XCTestCase {

    private func format(rate: Double = 48_000, channels: AVAudioChannelCount = 1,
                        interleaved: Bool = false) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                      channels: channels, interleaved: interleaved)!
    }

    /// Buffer whose sample values encode their absolute frame index, so
    /// ordering and completeness are verifiable.
    private func rampBuffer(format f: AVAudioFormat, frames: Int, startIndex: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        let channels = Int(f.channelCount)
        let d = b.floatChannelData!
        if f.isInterleaved {
            for i in 0..<frames {
                for c in 0..<channels { d[0][i * channels + c] = Float(startIndex + i) }
            }
        } else {
            for c in 0..<channels {
                for i in 0..<frames { d[c][i] = Float(startIndex + i) }
            }
        }
        return b
    }

    private func samples(_ b: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(b.frameLength)
        let channels = Int(b.format.channelCount)
        let d = b.floatChannelData!
        if b.format.isInterleaved {
            return Array(UnsafeBufferPointer(start: d[0], count: frames * channels))
        }
        return Array(UnsafeBufferPointer(start: d[0], count: frames))
    }

    // MARK: - Completeness / ordering

    func testDrainAllEmitsEveryFrameInOrder() {
        let f = format()
        let tl = GainTimeline()
        let p = DelayedMicPipeline(timeline: tl, format: f)

        let chunk = 512
        var t = 0.0
        for k in 0..<10 {
            p.enqueue(rampBuffer(format: f, frames: chunk, startIndex: k * chunk), t0: t)
            t += Double(chunk) / f.sampleRate
        }

        var out: [Float] = []
        var times: [Double] = []
        p.drainAll { buf, t0 in
            out.append(contentsOf: self.samples(buf))
            times.append(t0)
        }

        XCTAssertEqual(out.count, chunk * 10, "no frames may be lost")
        XCTAssertEqual(out, (0..<(chunk * 10)).map { Float($0) }, "order must be preserved")
        XCTAssertEqual(times, times.sorted(), "start times must be monotonic")
        XCTAssertEqual(p.queuedBuffers, 0)
    }

    /// With an empty timeline every gain is unity, and unity must not perturb
    /// a single sample — this is the kill-switch/headphone guarantee.
    func testUnityGainIsBitIdentical() {
        let f = format()
        let p = DelayedMicPipeline(timeline: GainTimeline(), format: f)
        let input = rampBuffer(format: f, frames: 1024, startIndex: 0)
        let expected = samples(input)

        p.enqueue(input, t0: 0)
        var got: [Float] = []
        p.drainAll { buf, _ in got = self.samples(buf) }

        XCTAssertEqual(got, expected)
    }

    // MARK: - Gain application

    func testConstantGainScalesAllSamples() {
        let f = format()
        let tl = GainTimeline()
        // Flat 0.5 across the whole span.
        for i in 0...200 { tl.append(gain: 0.5, frameTime: Double(i) * 0.016) }
        let p = DelayedMicPipeline(timeline: tl, format: f)

        let frames = 4096
        let input = rampBuffer(format: f, frames: frames, startIndex: 0)
        let expected = samples(input).map { $0 * 0.5 }
        p.enqueue(input, t0: 0.5)      // inside the timeline's span

        var got: [Float] = []
        p.drainAll { buf, _ in got = self.samples(buf) }
        XCTAssertEqual(got.count, expected.count)
        for i in 0..<got.count {
            XCTAssertEqual(got[i], expected[i], accuracy: 1e-4)
        }
    }

    func testInterleavedStereoIsScaledOnEveryChannel() {
        let f = format(channels: 2, interleaved: true)
        let tl = GainTimeline()
        for i in 0...200 { tl.append(gain: 0.25, frameTime: Double(i) * 0.016) }
        let p = DelayedMicPipeline(timeline: tl, format: f)

        let frames = 512
        p.enqueue(rampBuffer(format: f, frames: frames, startIndex: 0), t0: 0.5)
        var got: [Float] = []
        p.drainAll { buf, _ in
            let d = buf.floatChannelData!
            got = Array(UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength) * 2))
        }
        XCTAssertEqual(got.count, frames * 2)
        for i in 0..<frames {
            XCTAssertEqual(got[i * 2], Float(i) * 0.25, accuracy: 1e-3)
            XCTAssertEqual(got[i * 2 + 1], Float(i) * 0.25, accuracy: 1e-3)
        }
    }

    func testPlanarStereoIsScaledOnEveryChannel() {
        let f = format(channels: 2, interleaved: false)
        let tl = GainTimeline()
        for i in 0...200 { tl.append(gain: 0.25, frameTime: Double(i) * 0.016) }
        let p = DelayedMicPipeline(timeline: tl, format: f)

        let frames = 512
        p.enqueue(rampBuffer(format: f, frames: frames, startIndex: 0), t0: 0.5)
        p.drainAll { buf, _ in
            let d = buf.floatChannelData!
            for c in 0..<2 {
                for i in 0..<frames {
                    XCTAssertEqual(d[c][i], Float(i) * 0.25, accuracy: 1e-3)
                }
            }
        }
    }

    // MARK: - Release policy

    func testFlushHoldsBuffersUntilResolvedOrDeadline() {
        let f = format()
        let tl = GainTimeline()
        let p = DelayedMicPipeline(timeline: tl, format: f, lookaheadSeconds: 0.4)

        // 100 ms of audio starting at t=0.
        let frames = Int(0.1 * f.sampleRate)
        p.enqueue(rampBuffer(format: f, frames: frames, startIndex: 0), t0: 0)

        // Nothing on the timeline and only 200 ms elapsed → still held.
        var emitted = 0
        p.flushReady(now: 0.2) { _, _ in emitted += 1 }
        XCTAssertEqual(emitted, 0, "must wait for gains or the deadline")
        XCTAssertEqual(p.queuedBuffers, 1)

        // Analyzer resolves past the buffer's end → released immediately.
        tl.append(gain: 0.5, frameTime: 0.15)
        p.flushReady(now: 0.2) { _, _ in emitted += 1 }
        XCTAssertEqual(emitted, 1)
        XCTAssertEqual(p.queuedBuffers, 0)
    }

    /// If the analyzer stalls, the deadline must still drain the queue —
    /// otherwise memory grows without bound for the whole session.
    func testStalledAnalyzerStillDrainsAtDeadline() {
        let f = format()
        let tl = GainTimeline()          // never advances
        let p = DelayedMicPipeline(timeline: tl, format: f, lookaheadSeconds: 0.4)

        let frames = Int(0.1 * f.sampleRate)
        p.enqueue(rampBuffer(format: f, frames: frames, startIndex: 0), t0: 0)

        var emitted = 0
        p.flushReady(now: 0.2) { _, _ in emitted += 1 }
        XCTAssertEqual(emitted, 0)

        // now - lookahead = 0.6 > buffer end (0.1) → released at unity.
        p.flushReady(now: 1.0) { buf, _ in
            emitted += 1
            XCTAssertEqual(self.samples(buf), (0..<frames).map { Float($0) },
                           "stalled analyzer must pass audio through untouched")
        }
        XCTAssertEqual(emitted, 1)
        XCTAssertEqual(p.queuedBuffers, 0)
    }

    // MARK: - Concurrency

    /// Flushes are driven from both the mic callback and the levels timer.
    /// Concurrent flushes must not interleave: every frame is emitted exactly
    /// once, in order.
    func testConcurrentFlushesEmitEachFrameOnceInOrder() {
        let f = format()
        let tl = GainTimeline(capacityFrames: 8192)
        let p = DelayedMicPipeline(timeline: tl, format: f, lookaheadSeconds: 0.0)

        let chunk = 256
        let count = 200
        var t = 0.0
        for k in 0..<count {
            p.enqueue(rampBuffer(format: f, frames: chunk, startIndex: k * chunk), t0: t)
            t += Double(chunk) / f.sampleRate
        }

        let collected = NSMutableArray()
        let collectLock = NSLock()
        let done = expectation(description: "concurrent flush")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global().async {
                for _ in 0..<200 {
                    p.flushReady(now: 1e6) { buf, _ in
                        let s = self.samples(buf)
                        collectLock.lock(); collected.add(s); collectLock.unlock()
                    }
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)

        let flat = (collected as! [[Float]]).flatMap { $0 }
        XCTAssertEqual(flat.count, chunk * count, "every frame emitted exactly once")
        XCTAssertEqual(flat, (0..<(chunk * count)).map { Float($0) }, "order preserved across threads")
    }

    // MARK: - Deep copy

    /// Tap buffers are recycled by AVAudioEngine; the pipeline must not alias
    /// the caller's storage.
    func testEnqueueDeepCopiesSoCallerMayReuseTheBuffer() {
        let f = format()
        let p = DelayedMicPipeline(timeline: GainTimeline(), format: f)

        let scratch = rampBuffer(format: f, frames: 256, startIndex: 0)
        p.enqueue(scratch, t0: 0)

        // Simulate the engine reusing the buffer with new content.
        let d = scratch.floatChannelData!
        for i in 0..<256 { d[0][i] = -999 }

        var got: [Float] = []
        p.drainAll { buf, _ in got = self.samples(buf) }
        XCTAssertEqual(got, (0..<256).map { Float($0) },
                       "queued audio must be independent of the caller's buffer")
    }
}
