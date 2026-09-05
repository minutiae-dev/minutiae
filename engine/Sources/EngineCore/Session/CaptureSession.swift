import Accelerate
import AVFoundation
import Foundation

/// Orchestrates one recording session: system tap ("them") + mic ("me"),
/// shared session clock, per-channel disk writers and ASR feed paths
/// (Resampler → RingBuffer → WindowedTranscriber), and a 10 Hz levels timer.
///
/// start() is fast (<1 s): it only starts the captures — ASR models are
/// prepared at hello time when cached. Audio captured while the model is still
/// loading is HELD in each transcriber's ring buffer (up to its capacity) and
/// transcribed when `prepareTask` reports the engine ready, rather than being
/// handed to an engine that would reject it.
public final class CaptureSession: @unchecked Sendable {
    public let sessionId: String
    private let dir: URL
    private let micDeviceUid: String
    /// "them" channel source: "system" (process tap) or an input-device UID.
    private let themSource: String
    private let asrEngine: AsrEngine
    private let emit: @Sendable (EngineMessage) -> Void

    private let clock = SessionClock()
    private let micCapture = MicCapture()
    /// Exactly one of these is used for the "them" channel, per `themSource`.
    private var systemTap: SystemAudioTap?
    private var themDeviceCapture: MicCapture?
    private let indexAllocator = SegmentIndexAllocator()

    private var meWriter: AudioFileWriter?
    private var themWriter: AudioFileWriter?
    private var meTranscriber: WindowedTranscriber?
    private var themTranscriber: WindowedTranscriber?
    private var meResampler: Resampler?
    private var themResampler: Resampler?
    /// Separate 16 kHz feeds for echo analysis. These CANNOT share the ASR
    /// resamplers: AVAudioConverter is stateful, so one instance cannot convert
    /// the same buffer twice, and the `me` ASR resampler now runs later on the
    /// delayed path.
    private var meAnalysisResampler: Resampler?
    private var themAnalysisResampler: Resampler?

    /// Echo suppression (see EchoAnalyzer). Nil when disabled via env var.
    private let gainTimeline = GainTimeline()
    private var echoAnalyzer: EchoAnalyzer?
    private var micPipeline: DelayedMicPipeline?
    /// Debug side-car: the mic as captured, before suppression.
    private var meRawWriter: AudioFileWriter?
    private var loggedEngagement = false

    private let levelsQueue = DispatchQueue(label: "com.minutiae.engine.levels")
    private var levelsTimer: DispatchSourceTimer?

    // Latest per-channel buffer RMS (dBFS) + host-clock time of last update.
    private let levelLock = NSLock()
    private var meLevelDb: Double = -120
    private var themLevelDb: Double = -120
    private var meLevelAt: Double = -1
    private var themLevelAt: Double = -1

    private var prepareTask: Task<Void, Never>?
    private var stopped = false

    public init(sessionId: String, dir: URL, micDeviceUid: String,
                themSource: String = "system",
                asrEngine: AsrEngine,
                emit: @escaping @Sendable (EngineMessage) -> Void) {
        self.sessionId = sessionId
        self.dir = dir
        self.micDeviceUid = micDeviceUid
        self.themSource = themSource
        self.asrEngine = asrEngine
        self.emit = emit
    }

    public var t0EpochMs: Int64 { clock.t0EpochMs }

    public func start() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CaptureError.internalError("session dir does not exist: \(dir.path)")
        }

        // Mic first (its TCC failure mode is the common one), then system tap.
        let sessionId = self.sessionId
        let engineId = asrEngine.id

        try micCapture.start(deviceUID: micDeviceUid) { [weak self] buffer, hostTime in
            self?.handle(buffer: buffer, hostTime: hostTime, channel: .me)
        }

        // "them" source: system-audio process tap, or a chosen input device
        // (e.g. a loopback). Both deliver buffers through the same handler.
        let themHandler: (AVAudioPCMBuffer, UInt64) -> Void = { [weak self] buffer, hostTime in
            self?.handle(buffer: buffer, hostTime: hostTime, channel: .them)
        }
        let themFormat: AVAudioFormat
        do {
            if themSource.isEmpty || themSource == "system" {
                let tap = SystemAudioTap()
                try tap.start(onBuffer: themHandler)
                systemTap = tap
                guard let f = tap.tapFormat else {
                    throw CaptureError.internalError("system tap format unavailable after start")
                }
                themFormat = f
            } else {
                let device = MicCapture()
                try device.start(deviceUID: themSource, onBuffer: themHandler)
                themDeviceCapture = device
                guard let f = device.captureFormat else {
                    throw CaptureError.internalError("them device format unavailable after start")
                }
                themFormat = f
            }
        } catch {
            micCapture.stop()
            throw error
        }

        // Writers + ASR feeds, now that native formats are known.
        guard let micFormat = micCapture.captureFormat else {
            micCapture.stop()
            stopThemCapture()
            throw CaptureError.internalError("capture formats unavailable after start")
        }
        let tapFormat = themFormat
        do {
            meWriter = try AudioFileWriter(channel: .me, dir: dir, format: micFormat)
            themWriter = try AudioFileWriter(channel: .them, dir: dir, format: tapFormat)
        } catch {
            micCapture.stop()
            stopThemCapture()
            throw CaptureError.internalError("could not create audio files: \(error.localizedDescription)")
        }
        meResampler = Resampler(inputFormat: micFormat)
        themResampler = Resampler(inputFormat: tapFormat)

        // Echo suppression: on by default, opt-out via env var. When disabled
        // the mic path stays fully synchronous — the disable path carries no
        // delay line and therefore no risk at all.
        if ProcessInfo.processInfo.environment["MINUTIAE_ECHO_SUPPRESS"] != "0" {
            meAnalysisResampler = Resampler(inputFormat: micFormat)
            themAnalysisResampler = Resampler(inputFormat: tapFormat)
            echoAnalyzer = EchoAnalyzer(timeline: gainTimeline)
            micPipeline = DelayedMicPipeline(timeline: gainTimeline, format: micFormat)
            log("echo suppression enabled (output transport: \(AudioDevices.defaultOutputTransportDescription()))")

            if ProcessInfo.processInfo.environment["MINUTIAE_KEEP_RAW_ME"] == "1" {
                meRawWriter = try? AudioFileWriter(channel: .me, dir: dir, format: micFormat, nameSuffix: "-raw")
                log("keeping unprocessed mic capture (audio-me-raw)")
            }
        } else {
            log("echo suppression disabled via MINUTIAE_ECHO_SUPPRESS=0")
        }

        let emit = self.emit
        meTranscriber = WindowedTranscriber(channel: .me, engine: asrEngine, indexAllocator: indexAllocator) { segment in
            emit(.transcript(sessionId: sessionId, segment: segment))
        }
        themTranscriber = WindowedTranscriber(channel: .them, engine: asrEngine, indexAllocator: indexAllocator) { segment in
            emit(.transcript(sessionId: sessionId, segment: segment))
        }

        // Make sure models are ready (no-op when prepared at hello time).
        let asrEngine = self.asrEngine
        prepareTask = Task { [weak self] in
            do {
                try await asrEngine.prepare { pct, stage in
                    emit(.modelProgress(pct: pct * 100,
                                        stage: stage == "compiling" ? .compiling : .downloading))
                }
                // Whatever was captured during the load is still in the rings.
                self?.meTranscriber?.engineBecameReady()
                self?.themTranscriber?.engineBecameReady()
            } catch {
                log("model prepare failed during session: \(error)")
                emit(.error(code: .modelDownloadFailed,
                            message: "model download/compile failed: \(error)",
                            fatal: false, sessionId: sessionId))
            }
        }

        startLevelsTimer()
        log("session \(sessionId) started (engine \(engineId))")
    }

    /// Stops whichever "them" capture is active (system tap or device).
    private func stopThemCapture() {
        systemTap?.stop()
        systemTap = nil
        themDeviceCapture?.stop()
        themDeviceCapture = nil
    }

    private func handle(buffer: AVAudioPCMBuffer, hostTime: UInt64, channel: Channel) {
        let t = clock.seconds(fromHostTime: hostTime)

        // Level metering always reads the RAW buffer, for both channels.
        // Deliberately NOT the suppressed signal: routing the meter through the
        // delay line would add the full lookahead of lag to the UI, which is a
        // worse trade than the `me` meter twitching on far-end bleed.
        let db = Self.bufferRmsDbfs(buffer)
        let now = clock.now()
        levelLock.lock()
        if channel == .me {
            meLevelDb = db
            meLevelAt = now
        } else {
            themLevelDb = db
            themLevelAt = now
        }
        levelLock.unlock()

        if channel == .them {
            themWriter?.write(buffer, at: t)
            // Reference for suppression, before the ASR resample consumes it.
            if let r = themAnalysisResampler, let analyzer = echoAnalyzer {
                let ref = r.convert(buffer)
                if !ref.isEmpty { analyzer.pushFar(ref, at: t) }
            }
            if let resampler = themResampler, let transcriber = themTranscriber {
                let samples = resampler.convert(buffer)
                if !samples.isEmpty { transcriber.feed(samples: samples, firstSampleTime: t) }
            }
            return
        }

        // --- me channel ---
        guard let analyzer = echoAnalyzer, let pipeline = micPipeline,
              let analysisResampler = meAnalysisResampler else {
            // Suppression disabled: original synchronous path.
            emitMe(buffer: buffer, startTime: t)
            return
        }

        meRawWriter?.write(buffer, at: t)

        let nearSamples = analysisResampler.convert(buffer)
        if !nearSamples.isEmpty { analyzer.pushNear(nearSamples, at: t) }

        // Held until the gain envelope covers this buffer (or the lookahead
        // deadline passes), then emitted scaled.
        pipeline.enqueue(buffer, t0: t)
        pipeline.flushReady(now: now) { [weak self] gained, startTime in
            self?.emitMe(buffer: gained, startTime: startTime)
        }
        logEngagementOnce()
    }

    /// Writes and transcribes one `me` buffer. `startTime` is the ORIGINAL
    /// capture time, never the flush time — otherwise the lookahead would shift
    /// every transcript timestamp on this channel.
    private func emitMe(buffer: AVAudioPCMBuffer, startTime: Double) {
        meWriter?.write(buffer, at: startTime)
        guard let resampler = meResampler, let transcriber = meTranscriber else { return }
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        transcriber.feed(samples: samples, firstSampleTime: startTime)
    }

    /// One line the first time suppression engages — the primary field-debug
    /// signal for "was the echo path detected?".
    private func logEngagementOnce() {
        guard !loggedEngagement, let analyzer = echoAnalyzer, analyzer.isEngaged else { return }
        loggedEngagement = true
        let ms = Int((analyzer.estimatedDelaySeconds * 1000).rounded())
        log(String(format: "echo suppressor engaged (lag ≈ %d ms, confidence %.2f)", ms, analyzer.confidence))
    }

    /// Stops captures, drains the final partial ASR windows, finalizes the
    /// audio files (Opus transcode). Returns the data for session_stopped.
    public func stop() async -> (audio: [AudioFileInfo], stats: SessionStats) {
        guard !stopped else { return ([], SessionStats(segments: 0, droppedWindows: 0)) }
        stopped = true

        // Session time recording ended, for the writers' trailing pad. Read
        // before the captures stop so it is the moment of the last audio.
        let endTime = clock.now()
        stopLevelsTimer()
        micCapture.stop()
        stopThemCapture()
        prepareTask?.cancel()

        // ORDER IS LOAD-BEARING: the mic delay line still holds up to the
        // lookahead of audio. It must be drained into the writer and the
        // transcriber BEFORE they are finished/finalized below, or the last
        // ~400 ms of every recording is silently truncated.
        micPipeline?.drainAll { [weak self] gained, startTime in
            self?.emitMe(buffer: gained, startTime: startTime)
        }

        // Drain final partial windows through the ASR.
        await meTranscriber?.finish()
        await themTranscriber?.finish()

        var audio: [AudioFileInfo] = []
        if let meWriter { audio.append(meWriter.finalize(at: endTime)) }
        if let themWriter { audio.append(themWriter.finalize(at: endTime)) }
        // Debug side-car is finalized but never reported in audio[].
        _ = meRawWriter?.finalize(at: endTime)

        if let analyzer = echoAnalyzer {
            log(String(format: "echo suppressor: engaged=%@ confidence=%.2f lag=%d ms",
                       analyzer.isEngaged ? "yes" : "no",
                       analyzer.confidence,
                       Int((analyzer.estimatedDelaySeconds * 1000).rounded())))
        }

        let segments = (meTranscriber?.segmentsEmitted ?? 0) + (themTranscriber?.segmentsEmitted ?? 0)
        let dropped = (meTranscriber?.droppedWindows ?? 0) + (themTranscriber?.droppedWindows ?? 0)
        log("session \(sessionId) stopped (\(segments) segments, \(dropped) dropped windows)")
        return (audio, SessionStats(segments: segments, droppedWindows: dropped))
    }

    // MARK: - Levels (~10 Hz while recording)

    private func startLevelsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: levelsQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = self.clock.now()

            // Nudge the delay line: a silent or stalled mic delivers no buffers,
            // so without this the queue would sit un-flushed until the next one
            // arrives. Reuses this 10 Hz timer rather than adding another.
            self.micPipeline?.flushReady(now: now) { [weak self] gained, startTime in
                self?.emitMe(buffer: gained, startTime: startTime)
            }

            self.levelLock.lock()
            // Decay to silence if a channel stops delivering buffers.
            let me = (now - self.meLevelAt) < 0.3 ? self.meLevelDb : -120
            let them = (now - self.themLevelAt) < 0.3 ? self.themLevelDb : -120
            self.levelLock.unlock()
            self.emit(.levels(sessionId: self.sessionId, meDb: me, themDb: them))
        }
        timer.resume()
        levelsTimer = timer
    }

    private func stopLevelsTimer() {
        levelsTimer?.cancel()
        levelsTimer = nil
    }

    /// Mean square across all channels, via vDSP — this runs on every capture
    /// buffer of both channels (~105/s combined), so the scalar loop it
    /// replaced was one of the few pipeline functions visible in a profile.
    static func bufferRmsDbfs(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -120 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var meanSquare: Float = 0
        if buffer.format.isInterleaved {
            // Interleaved: one pass over frames*channels already averages
            // across channels as well as time.
            vDSP_measqv(data[0], 1, &meanSquare, vDSP_Length(frames * channels))
        } else {
            var total: Float = 0
            for ch in 0..<channels {
                var channelMean: Float = 0
                vDSP_measqv(data[ch], 1, &channelMean, vDSP_Length(frames))
                total += channelMean
            }
            meanSquare = total / Float(channels)
        }
        let rms = Double(meanSquare).squareRoot()
        guard rms > 0 else { return -120 }
        return max(-120, 20 * log10(rms))
    }
}
