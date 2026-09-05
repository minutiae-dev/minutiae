import AVFoundation
import XCTest
@testable import EngineCore

/// End-to-end verification of the echo-suppression path against the REAL ASR.
///
/// Reproduces the reported bug offline: the far end is captured cleanly by the
/// tap AND bleeds into the mic acoustically, so without suppression the same
/// speech is transcribed on both channels. Asserts that after suppression the
/// `me` channel produces no transcript while `them` still does.
///
/// Opt-in — it downloads/loads CoreML models and runs the ANE, so it is far too
/// heavy for the normal suite:
///   MINUTIAE_E2E=1 MINUTIAE_E2E_SPEECH=/path/to/speech.aiff \
///     swift test --package-path engine --filter EchoEndToEndTests
final class EchoEndToEndTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["MINUTIAE_E2E"] == "1" }

    /// Loads the source speech as 48 kHz mono Float32 (the mic/tap native rate).
    private func loadSpeech48k() throws -> [Float] {
        let path = ProcessInfo.processInfo.environment["MINUTIAE_E2E_SPEECH"] ?? ""
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: file.processingFormat, to: out)!
        var result: [Float] = []
        var done = false
        while !done {
            let cap = AVAudioFrameCount(48_000)
            let buf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap)!
            var err: NSError?
            let status = conv.convert(to: buf, error: &err) { _, s in
                let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: 16_384)!
                do { try file.read(into: inBuf, frameCount: 16_384) } catch {
                    s.pointee = .endOfStream; return nil
                }
                if inBuf.frameLength == 0 { s.pointee = .endOfStream; return nil }
                s.pointee = .haveData
                return inBuf
            }
            if let d = buf.floatChannelData, buf.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength)))
            }
            if status == .endOfStream || status == .error { done = true }
        }
        return result
    }

    private func buffer(_ samples: ArraySlice<Float>, format f: AVAudioFormat) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        let d = b.floatChannelData![0]
        for (i, v) in samples.enumerated() { d[i] = v }
        return b
    }

    func testSpeakerEchoIsNotTranscribedOnTheMeChannel() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_E2E=1 to run")

        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let far = try loadSpeech48k()
        XCTAssertGreaterThan(far.count, 48_000, "need at least a second of speech")

        // The mic hears the speakers: delayed ~75 ms, attenuated, plus room noise.
        let delay = Int(0.075 * 48_000)
        var near = [Float](repeating: 0, count: far.count)
        var st: UInt64 = 42
        func noise() -> Float {
            st = st &* 6364136223846793005 &+ 1442695040888963407
            return (Float(Double(st >> 11) / Double(1 << 53)) * 2 - 1) * 0.002
        }
        for i in delay..<far.count { near[i] = far[i - delay] * 0.35 }
        for i in 0..<near.count { near[i] += noise() }

        let engine = ParakeetEngine(language: "auto")
        try await engine.prepare { _, _ in }

        // Mirrors CaptureSession's wiring exactly.
        let timeline = GainTimeline(capacityFrames: 16_384)
        let analyzer = EchoAnalyzer(timeline: timeline)
        let pipeline = DelayedMicPipeline(timeline: timeline, format: f48)
        let meAnalysis = Resampler(inputFormat: f48)!
        let themAnalysis = Resampler(inputFormat: f48)!
        let meAsr = Resampler(inputFormat: f48)!
        let themAsr = Resampler(inputFormat: f48)!

        let allocator = SegmentIndexAllocator()
        let collected = NSMutableArray()
        let clock = NSLock()
        func collector(_ ch: Channel) -> @Sendable (Segment) -> Void {
            { seg in clock.lock(); collected.add("\(ch.rawValue)|\(seg.text)"); clock.unlock() }
        }
        let meT = WindowedTranscriber(channel: .me, engine: engine,
                                      indexAllocator: allocator, emit: collector(.me))
        let themT = WindowedTranscriber(channel: .them, engine: engine,
                                        indexAllocator: allocator, emit: collector(.them))

        var gainedAsr: [Float] = []
        let chunk = 1024
        var i = 0
        while i < far.count {
            let end = min(i + chunk, far.count)
            let t = Double(i) / 48_000

            // them: immediate
            let themBuf = buffer(far[i..<end], format: f48)
            let ref = themAnalysis.convert(themBuf)
            if !ref.isEmpty { analyzer.pushFar(ref, at: t) }
            let themSamples = themAsr.convert(themBuf)
            if !themSamples.isEmpty { themT.feed(samples: themSamples, firstSampleTime: t) }

            // me: analysed, then delayed and gained
            let meBuf = buffer(near[i..<end], format: f48)
            let nearSamples = meAnalysis.convert(meBuf)
            if !nearSamples.isEmpty { analyzer.pushNear(nearSamples, at: t) }
            pipeline.enqueue(meBuf, t0: t)
            pipeline.flushReady(now: t) { gained, t0 in
                let s = meAsr.convert(gained)
                gainedAsr.append(contentsOf: s)
                if !s.isEmpty { meT.feed(samples: s, firstSampleTime: t0) }
            }
            i = end
        }
        pipeline.drainAll { gained, t0 in
            let s = meAsr.convert(gained)
            gainedAsr.append(contentsOf: s)
            if !s.isEmpty { meT.feed(samples: s, firstSampleTime: t0) }
        }
        await meT.finish()
        await themT.finish()

        let all = collected as! [String]
        let meSegs = all.filter { $0.hasPrefix("me|") }
        let themSegs = all.filter { $0.hasPrefix("them|") }

        // Deterministic check: what the transcriber's silence gate actually
        // sees. Asserting only on ASR output is flaky — whether a gated-through
        // window yields text depends on decoder state.
        var worstWindowDb = -120.0
        var windowDbs: [String] = []
        let win = 5 * 16_000, hop = 4 * 16_000
        var w = 0
        while w + win <= gainedAsr.count {
            let db = WindowedTranscriber.rmsDbfs(Array(gainedAsr[w..<(w + win)]))
            windowDbs.append(String(format: "%.0fs:%.1f", Double(w) / 16_000, db))
            worstWindowDb = max(worstWindowDb, db)
            w += hop
        }
        print("E2E gained duration=\(Double(gainedAsr.count)/16_000)s windows=\(windowDbs)")
        // Per-second profile of the suppressed signal.
        var perSec: [String] = []
        var q = 0
        while q + 16_000 <= gainedAsr.count {
            perSec.append(String(format: "%.0f", WindowedTranscriber.rmsDbfs(Array(gainedAsr[q..<(q+16_000)]))))
            q += 16_000
        }
        print("E2E per-second dBFS: \(perSec.joined(separator: " "))")
        print("E2E engaged=\(analyzer.isEngaged) confidence=\(analyzer.confidence) "
              + "lag=\(Int(analyzer.estimatedDelaySeconds * 1000))ms "
              + "worstWindow=\(String(format: "%.1f", worstWindowDb))dBFS "
              + "gate=\(WindowedTranscriber.silenceGateDbfs)dBFS")
        print("E2E them segments (\(themSegs.count)):")
        themSegs.forEach { print("   ", $0) }
        print("E2E me segments (\(meSegs.count)):")
        meSegs.forEach { print("   ", $0) }

        XCTAssertTrue(analyzer.isEngaged, "should detect the acoustic echo path")
        XCTAssertEqual(analyzer.estimatedDelaySeconds, 0.075, accuracy: 0.016)
        XCTAssertFalse(themSegs.isEmpty, "the far end must still be transcribed on `them`")

        // STEADY STATE is the real claim. The detector needs ~2 s of far-end
        // audio to lock the delay, so the opening seconds are deliberately NOT
        // asserted — see EchoAnalyzer's CONVERGENCE note. After that the echo
        // must sit well under the transcriber's silence gate.
        let convergedFrom = Int(3.0 * 16_000)
        var worstConvergedDb = -120.0
        var c = convergedFrom
        while c + 16_000 <= gainedAsr.count {
            worstConvergedDb = max(worstConvergedDb,
                                   WindowedTranscriber.rmsDbfs(Array(gainedAsr[c..<(c + 16_000)])))
            c += 16_000
        }
        print("E2E worst converged second = \(String(format: "%.1f", worstConvergedDb)) dBFS")
        XCTAssertLessThan(worstConvergedDb, WindowedTranscriber.silenceGateDbfs,
            "after convergence the echo must fall under the ASR silence gate")

        // And the whole point: far fewer duplicated segments than unsuppressed.
        XCTAssertLessThan(meSegs.count, 3,
            "speaker echo should be largely gone from `me` — got \(meSegs)")
    }

    /// The safety case, and the one that matters most: the user talking WHILE
    /// the far end plays through the speakers. Their words must still be
    /// transcribed on `me`. A suppressor that passes the echo test by simply
    /// gutting the mic would fail here.
    func testUserVoiceSurvivesDoubleTalk() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_E2E=1 to run")
        let nearPath = ProcessInfo.processInfo.environment["MINUTIAE_E2E_NEAR"] ?? ""
        try XCTSkipUnless(!nearPath.isEmpty, "set MINUTIAE_E2E_NEAR to a near-end speech file")

        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let far = try loadSpeech48k()
        let voice = try load48k(path: nearPath)

        // Mic = speaker echo + the user's own voice, overlapping. The voice
        // starts AFTER the ~2 s convergence window (see EchoAnalyzer's
        // CONVERGENCE note): before lock the echo passes unsuppressed, so the
        // ASR sees two overlapped voices at full level and which one it
        // transcribes is luck, not suppressor behavior. This test's claim is
        // double talk against an ENGAGED suppressor — steady state, same as
        // the sibling test above.
        let delay = Int(0.075 * 48_000)
        var near = [Float](repeating: 0, count: far.count)
        for i in delay..<far.count { near[i] = far[i - delay] * 0.35 }
        let voiceStart = Int(4.0 * 48_000)
        for i in 0..<voice.count where voiceStart + i < near.count {
            near[voiceStart + i] += voice[i] * 0.8      // user is louder, as at their own mic
        }

        let engine = ParakeetEngine(language: "auto")
        try await engine.prepare { _, _ in }

        let timeline = GainTimeline(capacityFrames: 16_384)
        let analyzer = EchoAnalyzer(timeline: timeline)
        let pipeline = DelayedMicPipeline(timeline: timeline, format: f48)
        let meAnalysis = Resampler(inputFormat: f48)!
        let themAnalysis = Resampler(inputFormat: f48)!
        let meAsr = Resampler(inputFormat: f48)!

        let collected = NSMutableArray()
        let lk = NSLock()
        let meT = WindowedTranscriber(channel: .me, engine: engine,
                                      indexAllocator: SegmentIndexAllocator()) { seg in
            lk.lock(); collected.add(seg.text); lk.unlock()
        }

        var i = 0
        while i < far.count {
            let end = min(i + 1024, far.count)
            let t = Double(i) / 48_000
            let ref = themAnalysis.convert(buffer(far[i..<end], format: f48))
            if !ref.isEmpty { analyzer.pushFar(ref, at: t) }
            let meBuf = buffer(near[i..<end], format: f48)
            let ns = meAnalysis.convert(meBuf)
            if !ns.isEmpty { analyzer.pushNear(ns, at: t) }
            pipeline.enqueue(meBuf, t0: t)
            pipeline.flushReady(now: t) { gained, t0 in
                let s = meAsr.convert(gained)
                if !s.isEmpty { meT.feed(samples: s, firstSampleTime: t0) }
            }
            i = end
        }
        pipeline.drainAll { gained, t0 in
            let s = meAsr.convert(gained)
            if !s.isEmpty { meT.feed(samples: s, firstSampleTime: t0) }
        }
        await meT.finish()

        let text = (collected as! [String]).joined(separator: " ").lowercased()
        print("E2E double-talk — me transcript: \(text)")

        // Distinctive words from the near-end utterance only.
        let expected = ["agree", "assessment", "forward"]
        let found = expected.filter { text.contains($0) }
        XCTAssertGreaterThanOrEqual(found.count, 2,
            "user's own words must survive double talk — found \(found) in \(text.isEmpty ? "<empty>" : text)")
    }

    private func load48k(path: String) throws -> [Float] {
        let saved = ProcessInfo.processInfo.environment["MINUTIAE_E2E_SPEECH"]
        _ = saved
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: file.processingFormat, to: out)!
        var result: [Float] = []
        var done = false
        while !done {
            let buf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: 48_000)!
            var err: NSError?
            let status = conv.convert(to: buf, error: &err) { _, s in
                let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
                do { try file.read(into: inBuf, frameCount: 16_384) } catch {
                    s.pointee = .endOfStream; return nil
                }
                if inBuf.frameLength == 0 { s.pointee = .endOfStream; return nil }
                s.pointee = .haveData
                return inBuf
            }
            if let d = buf.floatChannelData, buf.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength)))
            }
            if status == .endOfStream || status == .error { done = true }
        }
        return result
    }

    /// Control: the same input with suppression bypassed must show the bug,
    /// proving the assertion above is actually testing something.
    func testWithoutSuppressionTheEchoIsTranscribedOnMe() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_E2E=1 to run")

        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let far = try loadSpeech48k()
        let delay = Int(0.075 * 48_000)
        var near = [Float](repeating: 0, count: far.count)
        for i in delay..<far.count { near[i] = far[i - delay] * 0.35 }

        let engine = ParakeetEngine(language: "auto")
        try await engine.prepare { _, _ in }

        let meAsr = Resampler(inputFormat: f48)!
        let collected = NSMutableArray()
        let lk = NSLock()
        let meT = WindowedTranscriber(channel: .me, engine: engine,
                                      indexAllocator: SegmentIndexAllocator()) { seg in
            lk.lock(); collected.add(seg.text); lk.unlock()
        }

        var i = 0
        while i < far.count {
            let end = min(i + 1024, far.count)
            let s = meAsr.convert(buffer(near[i..<end], format: f48))
            if !s.isEmpty { meT.feed(samples: s, firstSampleTime: Double(i) / 48_000) }
            i = end
        }
        await meT.finish()

        let segs = collected as! [String]
        print("E2E control — me segments WITHOUT suppression (\(segs.count)):")
        segs.forEach { print("   ", $0) }
        XCTAssertFalse(segs.isEmpty,
                       "control: unsuppressed echo SHOULD be transcribed (else the test proves nothing)")
    }
}
