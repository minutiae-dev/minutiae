import XCTest
@testable import EngineCore

/// Deterministic LCG — tests must not depend on system RNG.
private struct LCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    /// Uniform in [-1, 1).
    mutating func noise() -> Float {
        Float(Double(next() >> 11) / Double(1 << 53)) * 2 - 1
    }
}

final class EchoAnalyzerTests: XCTestCase {

    let sr = EchoAnalyzer.sampleRate   // 16 kHz

    // MARK: - Signal helpers

    /// Speech-like: band-limited noise under an *aperiodic* syllabic envelope
    /// — randomly-timed bursts with pauses, like real speech. The envelope
    /// modulation is what the delay estimator correlates on; a strictly
    /// periodic envelope would alias the correlation peak and is not
    /// representative.
    private func speechLike(seconds: Double, seed: UInt64, rateScale: Double = 1.0) -> [Float] {
        var rng = LCG(seed)
        let n = Int(seconds * sr)

        // Build a per-sample envelope of random bursts (80-250 ms) separated by
        // random pauses (60-200 ms), with raised-cosine ramps.
        var env = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let burst = Int((0.08 + 0.17 * Double(abs(rng.noise()))) * sr / rateScale)
            let pause = Int((0.06 + 0.14 * Double(abs(rng.noise()))) * sr / rateScale)
            let level = 0.5 + 0.5 * abs(rng.noise())
            let ramp = max(1, burst / 8)
            for k in 0..<burst where i + k < n {
                let shape: Float
                if k < ramp { shape = Float(k) / Float(ramp) }
                else if k > burst - ramp { shape = Float(burst - k) / Float(ramp) }
                else { shape = 1 }
                env[i + k] = level * shape
            }
            i += burst + pause
        }

        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for k in 0..<n {
            lp += 0.3 * (rng.noise() - lp)                // crude band limit
            out[k] = lp * env[k]
        }
        return out
    }

    /// Narrowband near-end "voice" in the 300-800 Hz band.
    private func nearVoice(seconds: Double, amplitude: Float) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { i in
            let t = Double(i) / sr
            let carrier = sin(2 * Double.pi * 450 * t) + 0.6 * sin(2 * Double.pi * 700 * t)
            let env = 0.6 + 0.4 * sin(2 * Double.pi * 4 * t)
            return amplitude * Float(carrier * env * 0.5)
        }
    }

    private func delayed(_ x: [Float], bySamples d: Int, gain: Float) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        for i in d..<x.count { out[i] = x[i - d] * gain }
        return out
    }

    private func mixed(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = min(a.count, b.count)
        return (0..<n).map { a[$0] + b[$0] }
    }

    private func rmsDb(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return -120 }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        let r = (sum / Double(x.count)).squareRoot()
        return r > 0 ? 20 * log10(r) : -120
    }

    // MARK: - Harness

    private struct RunResult {
        var gains: [Float]        // one per near sample
        var gained: [Float]
        var analyzer: EchoAnalyzer
    }

    /// Pushes both channels in lockstep 256-sample chunks (as the real capture
    /// callbacks do), then resolves the timeline at every near sample.
    private func run(near: [Float], far: [Float]) -> RunResult {
        let timeline = GainTimeline(capacityFrames: 8192)
        let analyzer = EchoAnalyzer(timeline: timeline)
        let chunk = 256
        var i = 0
        while i < near.count {
            let end = min(i + chunk, near.count)
            let t = Double(i) / sr
            if i < far.count {
                let fe = min(end, far.count)
                analyzer.pushFar(Array(far[i..<fe]), at: t)
            }
            analyzer.pushNear(Array(near[i..<end]), at: t)
            i = end
        }
        var gains = [Float](repeating: 1, count: near.count)
        var gained = [Float](repeating: 0, count: near.count)
        for k in 0..<near.count {
            let g = timeline.gain(atSessionTime: Double(k) / sr)
            gains[k] = g
            gained[k] = near[k] * g
        }
        return RunResult(gains: gains, gained: gained, analyzer: analyzer)
    }

    // MARK: - Product invariant: silence stays silent

    func testSilenceProducesUnityGainAndStaysSilent() {
        let n = Int(3 * sr)
        let silence = [Float](repeating: 0, count: n)
        let r = run(near: silence, far: silence)

        XCTAssertTrue(r.gains.allSatisfy { $0 == 1.0 },
                      "silence must not engage suppression")
        XCTAssertLessThanOrEqual(rmsDb(r.gained[0...]), -50.0,
                                 "silent input must stay below the ASR gate")
        XCTAssertFalse(r.analyzer.isEngaged)
    }

    /// The marketed guarantee, end to end through the transcriber's gate.
    func testSuppressedSilenceStillYieldsZeroSegments() async {
        let n = Int(3 * sr)
        let r = run(near: [Float](repeating: 0, count: n), far: [Float](repeating: 0, count: n))

        let engine = FakeAsrEngine(responses: ["should never be emitted"])
        var emitted = 0
        let lock = NSLock()
        let t = WindowedTranscriber(channel: .me, engine: engine,
                                    indexAllocator: SegmentIndexAllocator()) { _ in
            lock.lock(); emitted += 1; lock.unlock()
        }
        t.feed(samples: r.gained, firstSampleTime: 0)
        await t.finish()
        XCTAssertEqual(emitted, 0, "silence must produce zero transcript segments")
    }

    // MARK: - Echo suppression

    func testSyntheticEchoIsSuppressed() {
        let seconds = 8.0
        let far = speechLike(seconds: seconds, seed: 1)
        let delaySamples = 1200                      // 75 ms
        var near = delayed(far, bySamples: delaySamples, gain: 0.35)
        var rng = LCG(99)
        for i in 0..<near.count { near[i] += rng.noise() * 0.001 }   // ≈ −60 dBFS

        let r = run(near: near, far: far)

        XCTAssertTrue(r.analyzer.isEngaged, "should engage on a real echo path")
        XCTAssertGreaterThan(r.analyzer.confidence, 0.6)
        XCTAssertEqual(r.analyzer.estimatedDelaySeconds, 0.075, accuracy: 0.017,
                       "delay recovered within one analysis frame")

        // Measure over the last 2 s, after convergence.
        let tail = near.count - Int(2 * sr)
        let before = rmsDb(near[tail...])
        let after = rmsDb(r.gained[tail...])
        XCTAssertGreaterThanOrEqual(before - after, 15.0,
                                    "echo should be attenuated ≥ 15 dB (got \(before - after) dB)")
    }

    // MARK: - Double talk

    func testDoubleTalkPreservesNearVoice() {
        let seconds = 10.0
        let far = speechLike(seconds: seconds, seed: 7)
        let echo = delayed(far, bySamples: 1200, gain: 0.35)

        // Near-end voice present only during t ∈ [7, 8).
        var voice = [Float](repeating: 0, count: echo.count)
        let v = nearVoice(seconds: 1.0, amplitude: 0.30)
        let start = Int(7 * sr)
        for i in 0..<v.count where start + i < voice.count { voice[start + i] = v[i] }

        let near = mixed(echo, voice)
        let r = run(near: near, far: far)

        XCTAssertTrue(r.analyzer.isEngaged)

        let lo = Int(7.1 * sr), hi = Int(7.9 * sr)
        let beforeDb = rmsDb(near[lo..<hi])
        let afterDb = rmsDb(r.gained[lo..<hi])
        XCTAssertLessThan(beforeDb - afterDb, 3.0,
                          "near-end speech must survive double talk (lost \(beforeDb - afterDb) dB)")

        // And echo-only regions are still suppressed. Measured after the
        // near-end voice ends at t=8 s, so this is pure echo.
        let elo = Int(8.5 * sr), ehi = Int(9.5 * sr)
        XCTAssertGreaterThan(rmsDb(near[elo..<ehi]) - rmsDb(r.gained[elo..<ehi]), 10.0,
                             "echo-only stretch should still be suppressed")
    }

    /// Regression: a long near-end turn decorrelates the envelopes for many
    /// consecutive delay estimates. Confidence decay used to treat those
    /// rejections as "acoustic path gone" and fully disengage, snapping the
    /// gain to unity while the far end was still playing — the tail of a real
    /// meeting leaked every far-end sentence into the `me` transcript.
    func testSustainedDoubleTalkDoesNotDisengage() {
        let seconds = 20.0
        let far = speechLike(seconds: seconds, seed: 3)
        let echo = delayed(far, bySamples: 1200, gain: 0.35)

        // Near-end voice for 10 s (t = 5…15), louder than the echo — ten
        // consecutive estimate windows are contaminated.
        var voice = [Float](repeating: 0, count: echo.count)
        let v = nearVoice(seconds: 10.0, amplitude: 0.30)
        let start = Int(5 * sr)
        for i in 0..<v.count where start + i < voice.count { voice[start + i] = v[i] }

        let near = mixed(echo, voice)
        let r = run(near: near, far: far)

        XCTAssertTrue(r.analyzer.isEngaged,
                      "a locked suppressor must survive 10 s of double talk")

        // The user's voice must ride through the double-talk stretch.
        let vlo = Int(6 * sr), vhi = Int(14 * sr)
        let voiceLoss = rmsDb(near[vlo..<vhi]) - rmsDb(r.gained[vlo..<vhi])
        XCTAssertLessThan(voiceLoss, 3.0,
                          "near-end speech must survive (lost \(voiceLoss) dB)")

        // After the voice ends the near channel is pure echo again — it must
        // still be suppressed, not passed through at unity by a dropped lock.
        let elo = Int(17 * sr), ehi = Int(19.5 * sr)
        let reduction = rmsDb(near[elo..<ehi]) - rmsDb(r.gained[elo..<ehi])
        XCTAssertGreaterThanOrEqual(reduction, 10.0,
                                    "echo after double talk must stay suppressed (got \(reduction) dB)")
    }

    /// Regression: a >4× coupling jump during double talk (speaker volume up;
    /// the process tap reference is pre-volume, so only the mic side moves)
    /// used to latch the double-talk detector permanently — frozen coupling
    /// under-predicted the echo, pure echo kept reading as "user talking",
    /// which kept coupling frozen, while the 4× outlier gate blocked
    /// adaptation even on clean frames. Echo then passed at near-unity for
    /// the rest of the session.
    func testCouplingReseedRecoversFromEchoLevelJump() {
        let seconds = 20.0
        let far = speechLike(seconds: seconds, seed: 5)
        var near = delayed(far, bySamples: 1200, gain: 0.08)
        // Acoustic coupling jumps ~17 dB at t = 8 s.
        let step = Int(8 * sr)
        for i in step..<near.count { near[i] *= 7.0 }

        let r = run(near: near, far: far)

        XCTAssertTrue(r.analyzer.isEngaged)

        // Allow a few seconds for the false-latch detection (the window must
        // fill with flagged frames) plus the 1 s reseed, then require real
        // suppression again.
        let lo = Int(14 * sr), hi = Int(19.5 * sr)
        let reduction = rmsDb(near[lo..<hi]) - rmsDb(r.gained[lo..<hi])
        XCTAssertGreaterThanOrEqual(reduction, 10.0,
                                    "coupling must recover after a level jump (got \(reduction) dB)")
    }

    // MARK: - Headphones / no acoustic path

    func testUncorrelatedChannelsArePassedThroughBitIdentical() {
        let seconds = 8.0
        let far = speechLike(seconds: seconds, seed: 11)
        let near = speechLike(seconds: seconds, seed: 22, rateScale: 1.7)

        let r = run(near: near, far: far)

        XCTAssertFalse(r.analyzer.isEngaged, "no echo path — must not engage")
        XCTAssertLessThan(r.analyzer.confidence, EchoAnalyzer.engageThreshold)
        XCTAssertTrue(r.gains.allSatisfy { $0 == 1.0 }, "gain must be exactly unity")
        for i in 0..<near.count {
            XCTAssertEqual(r.gained[i], near[i], "samples must be bit-identical")
            if r.gained[i] != near[i] { break }
        }
    }

    // MARK: - Robustness

    func testRecoversAfterFarEndVolumeStep() {
        let seconds = 12.0
        var far = speechLike(seconds: seconds, seed: 5)
        // Far end gets 10 dB louder at t = 6 s.
        let step = Int(6 * sr)
        for i in step..<far.count { far[i] *= 3.16 }
        let near = delayed(far, bySamples: 1200, gain: 0.35)

        let r = run(near: near, far: far)

        XCTAssertTrue(r.analyzer.isEngaged)
        let lo = Int(8.0 * sr), hi = Int(10.0 * sr)   // ≥1.5 s after the step
        let reduction = rmsDb(near[lo..<hi]) - rmsDb(r.gained[lo..<hi])
        XCTAssertGreaterThanOrEqual(reduction, 12.0,
                                    "should recover after a volume change (got \(reduction) dB)")
    }

    // MARK: - Spectrum sanity

    func testBandEnergiesTrackToneFrequency() {
        let timeline = GainTimeline()
        let a = EchoAnalyzer(timeline: timeline)
        // 2 kHz tone → band 4 (1600-2400 Hz) should dominate.
        let frame = (0..<EchoAnalyzer.frameSize).map { i in
            Float(sin(2 * Double.pi * 2000 * Double(i) / self.sr))
        }
        let bands = a.bandEnergies(frame)
        let peak = bands.firstIndex(of: bands.max()!)!
        XCTAssertEqual(peak, 4, "2 kHz should land in the 1600-2400 Hz band")
    }
}
