import AVFoundation
import XCTest
@testable import EngineCore

/// Long-silence robustness. Meetings are mostly people NOT talking, and the
/// marketed guarantee is that silence produces zero transcript segments — so
/// the pipeline has to survive minutes of nothing without drifting timestamps,
/// growing without bound, or coming back deaf.
///
/// These run in the normal suite: they use the stub ASR and drive synthetic
/// audio far faster than realtime.
final class SilenceSoakTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutiae-soak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Speech → a long silent break → speech. The second burst must still be
    /// transcribed, and its timestamps must land on the real wall-clock time of
    /// the audio, not drift by the length of the silence.
    func testTimestampsSurviveALongSilentBreak() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = 30
        config.silentSeconds = 300      // 5 minutes of nothing
        let asr = CountingAsrEngine()
        let session = try SyntheticSession(dir: dir, config: config, engine: asr)

        // 30 s speech, 300 s silence, 30 s speech.
        session.run(seconds: 390)
        _ = await session.finish()

        let segments = session.collected.segments
        XCTAssertFalse(segments.isEmpty, "speech before and after the break must transcribe")

        let early = segments.filter { $0.t0 < 60 }
        let late = segments.filter { $0.t0 >= 300 }
        XCTAssertFalse(early.isEmpty, "the opening burst must be transcribed")
        XCTAssertFalse(late.isEmpty, "the engine must still be listening after 5 minutes of silence")

        // Nothing may be timestamped inside the silent break.
        let insideBreak = segments.filter { $0.t0 > 36 && $0.t1 < 328 }
        XCTAssertTrue(insideBreak.isEmpty,
                      "silence must produce zero segments — got \(insideBreak.map { ($0.t0, $0.text) })")

        // The post-break burst starts at 330 s; allow a window's worth of slack.
        let firstLate = try XCTUnwrap(late.map(\.t0).min())
        XCTAssertGreaterThan(firstLate, 320, "post-break segment timestamped too early — stream position drifted")
        XCTAssertLessThan(firstLate, 372, "post-break segment timestamped too late — stream position drifted")
    }

    /// The hard product guarantee, end-to-end through the real capture wiring
    /// rather than the transcriber in isolation: a silent session never reaches
    /// the ASR at all.
    func testLongSilenceNeverReachesTheAsr() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = 0
        config.silentSeconds = 1
        let asr = CountingAsrEngine()
        let session = try SyntheticSession(dir: dir, config: config, engine: asr)

        session.run(seconds: 600)       // 10 minutes
        _ = await session.finish()

        XCTAssertEqual(asr.calls, 0, "silence must never invoke the ASR")
        XCTAssertTrue(session.collected.segments.isEmpty, "silence must produce zero segments")
    }

    /// Memory must not creep across a long session. A leak here is invisible in
    /// a 30-second manual test and fatal in a two-hour meeting.
    func testFootprintIsFlatAcrossALongSession() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = 20
        config.silentSeconds = 40
        let asr = CountingAsrEngine()
        let session = try SyntheticSession(dir: dir, config: config, engine: asr)

        session.run(seconds: 120)               // warm up allocators
        let settled = ProcMetrics.footprint()
        session.run(seconds: 600)               // 10 more minutes
        let after = ProcMetrics.footprint()
        _ = await session.finish()

        let growthMB = Double(Int64(after) - Int64(settled)) / 1_048_576
        XCTAssertLessThan(growthMB, 12,
            "footprint grew \(String(format: "%.1f", growthMB)) MB over 10 minutes of session — leak?")
    }

    /// The reported bug, end to end: the system tap's IOProc does not run while
    /// the output device is idle, so a session that starts quiet gets its first
    /// `them` buffer well after time zero. The two recordings must still span
    /// the same session — otherwise playing them together drifts by however
    /// long the meeting was quiet before the first sound.
    func testLateStartingTapStillProducesAlignedChannels() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = 30
        config.silentSeconds = 0
        config.themStartDelay = 9.3          // nothing playing for the first 9.3 s
        let session = try SyntheticSession(dir: dir, config: config, engine: CountingAsrEngine())

        session.run(seconds: 30)
        let files = await session.finish(at: 30)

        let me = files.first { $0.channel == .me }!
        let them = files.first { $0.channel == .them }!
        XCTAssertEqual(them.durationS, me.durationS, accuracy: 0.2,
                       "them started \(config.themStartDelay) s late — its file must be padded, not short")
        XCTAssertEqual(them.durationS, 30, accuracy: 0.3)
    }

    /// A tap that stops mid-session and resumes must leave a hole of the right
    /// length in the file, and must not shift the transcript timestamps of
    /// everything that follows it earlier.
    func testMidSessionTapOutageKeepsTimestampsTrue() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = 60
        config.silentSeconds = 0
        config.themGap = 10...30             // the tap delivers nothing for 20 s
        let session = try SyntheticSession(dir: dir, config: config, engine: CountingAsrEngine())

        session.run(seconds: 60)
        let files = await session.finish(at: 60)

        let them = files.first { $0.channel == .them }!
        XCTAssertEqual(them.durationS, 60, accuracy: 0.5,
                       "the outage must be padded, not closed up")

        let themSegments = session.collected.segments.filter { $0.channel == .them }
        XCTAssertFalse(themSegments.isEmpty)
        // Every segment must sit inside the session, and none may claim to
        // describe audio from inside the hole.
        for seg in themSegments {
            XCTAssertGreaterThanOrEqual(seg.t0, -0.01)
            XCTAssertLessThanOrEqual(seg.t1, 60.5)
        }
        let insideHole = themSegments.filter { $0.t0 > 11 && $0.t1 < 29 }
        XCTAssertTrue(insideHole.isEmpty,
                      "no transcript may come from a stretch the tap never delivered")
    }

    /// Nothing may accumulate in the delay line across a long silent stretch:
    /// silent mic buffers still arrive and still have to drain.
    func testDelayLineDoesNotAccumulateDuringSilence() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = 0
        config.silentSeconds = 1
        let asr = CountingAsrEngine()
        let session = try SyntheticSession(dir: dir, config: config, engine: asr)

        session.run(seconds: 300)
        // 0.4 s lookahead at 4096-frame (85 ms) mic buffers ≈ 5 buffers held.
        XCTAssertLessThan(session.pipeline!.queuedBuffers, 16,
                          "delay line is accumulating during silence")
        _ = await session.finish()
        XCTAssertEqual(session.pipeline!.queuedBuffers, 0, "delay line must be empty after drainAll")
    }

    /// The common real-world case: nobody is sharing audio, so the `them` tap
    /// delivers nothing at all for the whole session. The user's own voice must
    /// be transcribed, and the suppressor must stay at bit-identical unity —
    /// there is no reference, so there is nothing it could legitimately do.
    func testMeChannelIsUntouchedWhenThemNeverDelivers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let timeline = GainTimeline()
        let analyzer = EchoAnalyzer(timeline: timeline)
        let pipeline = DelayedMicPipeline(timeline: timeline, format: f48)
        let analysis = Resampler(inputFormat: f48)!
        var source = SyntheticSpeech(sampleRate: 48_000)

        var emitted: [Float] = []
        var input: [Float] = []
        var t = 0.0
        var frame = [Float](repeating: 0, count: 4096)
        while t < 90 {
            source.render(into: &frame, startTime: t, speaking: true)
            input.append(contentsOf: frame)
            let buf = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 4096)!
            buf.frameLength = 4096
            frame.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: 4096) }
            let near = analysis.convert(buf)
            if !near.isEmpty { analyzer.pushNear(near, at: t) }
            pipeline.enqueue(buf, t0: t)
            pipeline.flushReady(now: t) { gained, _ in
                emitted.append(contentsOf: UnsafeBufferPointer(
                    start: gained.floatChannelData![0], count: Int(gained.frameLength)))
            }
            t += 4096.0 / 48_000
        }
        pipeline.drainAll { gained, _ in
            emitted.append(contentsOf: UnsafeBufferPointer(
                start: gained.floatChannelData![0], count: Int(gained.frameLength)))
        }

        XCTAssertFalse(analyzer.isEngaged, "no far-end reference — the suppressor must not engage")
        XCTAssertEqual(emitted.count, input.count, "every mic sample must come out of the delay line")
        // Bit-identical passthrough is the invariant, not "close enough".
        XCTAssertEqual(emitted, input, "mic audio was altered with no far-end reference")
    }

    /// A far end that goes quiet for minutes and comes back must still be
    /// suppressed — the analyzer may not quietly disengage over the gap.
    func testSuppressorSurvivesAFarEndGap() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = 25
        config.silentSeconds = 240
        let asr = CountingAsrEngine()
        let session = try SyntheticSession(dir: dir, config: config, engine: asr)

        session.run(seconds: 25)                     // lock onto the echo path
        let engagedBefore = session.analyzer!.isEngaged
        let lagBefore = session.analyzer!.estimatedDelaySeconds
        session.run(seconds: 240)                    // 4 minutes of silence
        XCTAssertEqual(session.analyzer!.isEngaged, engagedBefore,
                       "a silent gap must not change the suppressor's engagement")
        if engagedBefore {
            XCTAssertEqual(session.analyzer!.estimatedDelaySeconds, lagBefore, accuracy: 0.02,
                           "the locked lag must survive a silent gap")
        }
        _ = await session.finish()
    }

    /// Finalizing a channel that never received a single buffer must not throw
    /// or produce a bogus duration — this is what happens when a meeting has no
    /// system audio at all.
    func testEmptyChannelFinalizesCleanly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 2, interleaved: true)!
        let writer = try AudioFileWriter(channel: .them, dir: dir, format: f48)
        let info = writer.finalize()
        XCTAssertEqual(info.durationS, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path),
                      "an empty channel must still leave a readable file at the reported path")
    }
}

/// The recording path itself: mono 16-bit scratch WAV during capture, Opus
/// encoded incrementally in the background, and a CAF at the end that actually
/// decodes back to the audio that went in.
final class AudioFileWriterTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutiae-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(seconds: Double, format: AVAudioFormat, dir: URL,
                       chunkFrames: AVAudioFrameCount = 512) throws -> AudioFileInfo {
        let writer = try AudioFileWriter(channel: .them, dir: dir, format: format)
        var source = SyntheticSpeech(sampleRate: format.sampleRate)
        var mono = [Float](repeating: 0, count: Int(chunkFrames))
        var t = 0.0
        let step = Double(chunkFrames) / format.sampleRate
        while t < seconds {
            source.render(into: &mono, startTime: t, speaking: true)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
            buf.frameLength = chunkFrames
            let d = buf.floatChannelData!
            let ch = Int(format.channelCount)
            if format.isInterleaved {
                for i in 0..<mono.count { for c in 0..<ch { d[0][i * ch + c] = mono[i] } }
            } else {
                for c in 0..<ch { for i in 0..<mono.count { d[c][i] = mono[i] } }
            }
            writer.write(buf)
            t += step
        }
        return writer.finalize()
    }

    /// A stereo interleaved tap must land as a mono Opus CAF that decodes to
    /// the right duration — and the scratch WAV must be gone.
    func testStereoTapBecomesMonoOpus() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tap = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 2, interleaved: true)!
        let info = try write(seconds: 12, format: tap, dir: dir)

        XCTAssertEqual(info.codec, "opus")
        XCTAssertEqual(info.container, "caf")
        XCTAssertEqual(info.durationS, 12, accuracy: 0.1)

        XCTAssertEqual(info.sampleRate, AudioFileWriter.maxOpusSampleRate,
                       "metadata must describe the FILE's rate, not the capture device's")

        let decoded = try AVAudioFile(forReading: URL(fileURLWithPath: info.path))
        XCTAssertEqual(decoded.processingFormat.channelCount, 1, "recording must be mono")
        XCTAssertEqual(decoded.processingFormat.sampleRate, AudioFileWriter.maxOpusSampleRate,
                       "a 48 kHz capture must be archived at the capped rate")
        let decodedSeconds = Double(decoded.length) / decoded.processingFormat.sampleRate
        XCTAssertEqual(decodedSeconds, 12, accuracy: 0.25,
                       "the incrementally-encoded CAF must decode to the full session")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("audio-them.part.wav").path),
            "the scratch WAV must be removed once the CAF is complete")
    }

    /// Non-Opus capture rates (44.1 kHz) go through the resampling path.
    func testOddCaptureRateStillEncodes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                channels: 1, interleaved: false)!
        let info = try write(seconds: 6, format: fmt, dir: dir)
        XCTAssertEqual(info.codec, "opus")
        let decoded = try AVAudioFile(forReading: URL(fileURLWithPath: info.path))
        XCTAssertGreaterThan(decoded.length, 0)
        XCTAssertEqual(Double(decoded.length) / decoded.processingFormat.sampleRate, 6, accuracy: 0.25)
    }

    /// A low capture rate (AirPods deliver 16 kHz) must not be upsampled.
    func testLowCaptureRateIsNotUpsampled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let info = try write(seconds: 6, format: fmt, dir: dir)
        XCTAssertEqual(info.codec, "opus")
        let decoded = try AVAudioFile(forReading: URL(fileURLWithPath: info.path))
        XCTAssertEqual(decoded.processingFormat.sampleRate, 16_000,
                       "a 16 kHz capture is already at the cap — it must not be resampled either way")
    }

    /// If the background encoder ever falls far behind, the writer stops
    /// feeding it and transcodes the (complete) scratch WAV at stop instead.
    /// The recording must survive that path intact — this test provokes it by
    /// pushing five minutes of audio as fast as the machine can.
    func testEncoderOverrunStillProducesAValidRecording() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 2, interleaved: true)!
        // No waitForEncoder() anywhere: the backlog guard is meant to trip.
        let info = try write(seconds: 300, format: fmt, dir: dir)

        XCTAssertEqual(info.codec, "opus", "the fallback transcode must still yield Opus")
        XCTAssertEqual(info.durationS, 300, accuracy: 0.5)
        let decoded = try AVAudioFile(forReading: URL(fileURLWithPath: info.path))
        XCTAssertEqual(decoded.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(decoded.length) / decoded.processingFormat.sampleRate, 300,
                       accuracy: 1.0, "the fallback must not lose audio")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("audio-them.part.wav").path),
            "the scratch WAV must still be cleaned up on the fallback path")
    }

    // MARK: - Session-time alignment

    /// Feeds `chunks` of (startTime, seconds) with silence implied between them.
    private func writeTimed(_ spans: [(at: Double, seconds: Double)],
                            format: AVAudioFormat, dir: URL,
                            finalizeAt: Double? = nil,
                            chunkFrames: AVAudioFrameCount = 512) throws -> AudioFileInfo {
        let writer = try AudioFileWriter(channel: .them, dir: dir, format: format)
        var source = SyntheticSpeech(sampleRate: format.sampleRate)
        var mono = [Float](repeating: 0, count: Int(chunkFrames))
        let step = Double(chunkFrames) / format.sampleRate
        for span in spans {
            var t = span.at
            while t < span.at + span.seconds {
                source.render(into: &mono, startTime: t, speaking: true)
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
                buf.frameLength = chunkFrames
                let d = buf.floatChannelData!
                let ch = Int(format.channelCount)
                if format.isInterleaved {
                    for i in 0..<mono.count { for c in 0..<ch { d[0][i * ch + c] = mono[i] } }
                } else {
                    for c in 0..<ch { for i in 0..<mono.count { d[c][i] = mono[i] } }
                }
                writer.write(buf, at: t)
                t += step
            }
            writer.waitForEncoder()
        }
        return writer.finalize(at: finalizeAt)
    }

    private func format48Stereo() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                      channels: 2, interleaved: true)!
    }

    /// The reported bug: the process tap's IOProc does not run while the output
    /// device is idle, so a 24.7 s session produced a 15.4 s file whose first
    /// sample was the first sound — every transcript timestamp then pointed at
    /// the wrong place in the recording.
    func testLateStartingSourceIsPaddedToSessionZero() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let info = try writeTimed([(at: 9.3, seconds: 6)], format: format48Stereo(), dir: dir)

        XCTAssertEqual(info.durationS, 15.3, accuracy: 0.1,
                       "the file must start at session zero, not at the first sound")
        let decoded = try AVAudioFile(forReading: URL(fileURLWithPath: info.path))
        XCTAssertEqual(Double(decoded.length) / decoded.processingFormat.sampleRate,
                       15.3, accuracy: 0.3)
    }

    /// A source that stops mid-session and comes back must not have the hole
    /// closed up: everything after it would slide earlier by its length.
    func testMidSessionGapIsPaddedWithSilence() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let info = try writeTimed([(at: 0, seconds: 4), (at: 7, seconds: 4)],
                                  format: format48Stereo(), dir: dir)
        XCTAssertEqual(info.durationS, 11, accuracy: 0.1)

        // The hole itself must actually be silent in the decoded audio.
        let decoded = try AVAudioFile(forReading: URL(fileURLWithPath: info.path))
        let rate = decoded.processingFormat.sampleRate
        decoded.framePosition = AVAudioFramePosition(5.5 * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat,
                                   frameCapacity: AVAudioFrameCount(rate))!
        try decoded.read(into: buf, frameCount: AVAudioFrameCount(rate))
        let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0],
                                                count: Int(buf.frameLength)))
        XCTAssertLessThan(WindowedTranscriber.rmsDbfs(samples), -50,
                          "the gap must be silence, not the audio that came after it")
    }

    /// Recording keeps running after the far end goes quiet, so the file has to
    /// span the whole session — otherwise the two channels end at different
    /// times and playing them together drifts.
    func testTrailingSilenceIsPaddedAtFinalize() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = try writeTimed([(at: 0, seconds: 5)], format: format48Stereo(),
                                  dir: dir, finalizeAt: 12)
        XCTAssertEqual(info.durationS, 12, accuracy: 0.1)
    }

    /// Ordinary back-to-back buffers jitter by microseconds. None of that may
    /// be mistaken for a gap, or an hour of audio would accumulate pad.
    func testConsecutiveBuffersAreNeverPadded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let writer = try AudioFileWriter(channel: .them, dir: dir, format: fmt)
        let frames: AVAudioFrameCount = 512
        let step = Double(frames) / 48_000
        var t = 0.0
        var jitter = 0.0
        for i in 0..<900 {                       // ~9.6 s
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            for j in 0..<Int(frames) { buf.floatChannelData![0][j] = j % 2 == 0 ? 0.2 : -0.2 }
            // ±5 ms of jitter, plus a slow drift, on every buffer.
            jitter = (i % 2 == 0 ? 0.005 : -0.005)
            writer.write(buf, at: t + jitter)
            t += step
        }
        writer.waitForEncoder()
        let info = writer.finalize()
        XCTAssertEqual(info.durationS, t, accuracy: 0.05,
                       "buffer jitter must never be mistaken for a capture gap")
    }

    /// A channel that never delivered anything is not a channel of silence —
    /// reporting one would claim a source that was never there.
    func testEmptyChannelIsNotPadded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try AudioFileWriter(channel: .them, dir: dir, format: format48Stereo())
        let info = writer.finalize(at: 30)
        XCTAssertEqual(info.durationS, 0)
    }

    /// Finalizing must be fast: the encode happens during the session, so stop
    /// only drains a sub-second backlog. This is the difference between a
    /// meeting ending instantly and the user watching a spinner for a minute.
    func testFinalizeIsFast() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 2, interleaved: true)!
        let writer = try AudioFileWriter(channel: .them, dir: dir, format: fmt)
        var source = SyntheticSpeech(sampleRate: 48_000)
        var mono = [Float](repeating: 0, count: 512)
        var t = 0.0
        while t < 300 {                       // 5 minutes of audio
            source.render(into: &mono, startTime: t, speaking: true)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
            buf.frameLength = 512
            let d = buf.floatChannelData!
            for i in 0..<512 { d[0][i * 2] = mono[i]; d[0][i * 2 + 1] = mono[i] }
            writer.write(buf)
            t += 512.0 / 48_000
            // Audio arrives at 1x realtime in production and the encoder runs
            // ~120x faster, so it is never more than a chunk behind. This loop
            // is ~700x realtime, so pace it — otherwise the backlog guard trips
            // and we would be timing the fallback transcode instead.
            if Int(t * 10) % 100 == 0 { writer.waitForEncoder() }
        }
        // In a real session audio arrives at 1x realtime and the encoder runs
        // ~120x faster, so its backlog is always about one chunk. This test
        // pushed 5 minutes in a fraction of a second, so let it catch up first
        // — what is being asserted is that stop does NOT re-encode the session.
        writer.waitForEncoder()
        let started = CFAbsoluteTimeGetCurrent()
        let info = writer.finalize()
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(info.codec, "opus")
        XCTAssertLessThan(elapsed, 0.5,
            "finalize took \(String(format: "%.2f", elapsed)) s for 5 minutes of audio — "
            + "stop is re-encoding the session instead of just closing the file")
    }
}
