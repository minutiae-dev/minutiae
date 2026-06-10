import AVFoundation
import Foundation

/// Orchestrates one recording session: system tap ("them") + mic ("me"),
/// shared session clock, per-channel disk writers and ASR feed paths
/// (Resampler → RingBuffer → WindowedTranscriber), and a 10 Hz levels timer.
///
/// start() is fast (<1 s): it only starts the captures — ASR models are
/// prepared at hello time when cached. Audio buffered in the ring while the
/// model warms up is transcribed as soon as the engine is ready.
public final class CaptureSession: @unchecked Sendable {
    public let sessionId: String
    private let dir: URL
    private let micDeviceUid: String
    private let asrEngine: AsrEngine
    private let emit: @Sendable (EngineMessage) -> Void

    private let clock = SessionClock()
    private let systemTap = SystemAudioTap()
    private let micCapture = MicCapture()
    private let indexAllocator = SegmentIndexAllocator()

    private var meWriter: AudioFileWriter?
    private var themWriter: AudioFileWriter?
    private var meTranscriber: WindowedTranscriber?
    private var themTranscriber: WindowedTranscriber?
    private var meResampler: Resampler?
    private var themResampler: Resampler?

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
                asrEngine: AsrEngine,
                emit: @escaping @Sendable (EngineMessage) -> Void) {
        self.sessionId = sessionId
        self.dir = dir
        self.micDeviceUid = micDeviceUid
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
        do {
            try systemTap.start { [weak self] buffer, hostTime in
                self?.handle(buffer: buffer, hostTime: hostTime, channel: .them)
            }
        } catch {
            micCapture.stop()
            throw error
        }

        // Writers + ASR feeds, now that native formats are known.
        guard let micFormat = micCapture.captureFormat, let tapFormat = systemTap.tapFormat else {
            micCapture.stop()
            systemTap.stop()
            throw CaptureError.internalError("capture formats unavailable after start")
        }
        do {
            meWriter = try AudioFileWriter(channel: .me, dir: dir, format: micFormat)
            themWriter = try AudioFileWriter(channel: .them, dir: dir, format: tapFormat)
        } catch {
            micCapture.stop()
            systemTap.stop()
            throw CaptureError.internalError("could not create audio files: \(error.localizedDescription)")
        }
        meResampler = Resampler(inputFormat: micFormat)
        themResampler = Resampler(inputFormat: tapFormat)

        let emit = self.emit
        meTranscriber = WindowedTranscriber(channel: .me, engine: asrEngine, indexAllocator: indexAllocator) { segment in
            emit(.transcript(sessionId: sessionId, segment: segment))
        }
        themTranscriber = WindowedTranscriber(channel: .them, engine: asrEngine, indexAllocator: indexAllocator) { segment in
            emit(.transcript(sessionId: sessionId, segment: segment))
        }

        // Make sure models are ready (no-op when prepared at hello time).
        let asrEngine = self.asrEngine
        prepareTask = Task {
            do {
                try await asrEngine.prepare { pct, stage in
                    emit(.modelProgress(pct: pct * 100,
                                        stage: stage == "compiling" ? .compiling : .downloading))
                }
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

    private func handle(buffer: AVAudioPCMBuffer, hostTime: UInt64, channel: Channel) {
        let writer = channel == .me ? meWriter : themWriter
        writer?.write(buffer)

        let resampler = channel == .me ? meResampler : themResampler
        let transcriber = channel == .me ? meTranscriber : themTranscriber

        // Level metering from the raw buffer (mixed down).
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

        guard let resampler, let transcriber else { return }
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        transcriber.feed(samples: samples, firstSampleTime: clock.seconds(fromHostTime: hostTime))
    }

    /// Stops captures, drains the final partial ASR windows, finalizes the
    /// audio files (Opus transcode). Returns the data for session_stopped.
    public func stop() async -> (audio: [AudioFileInfo], stats: SessionStats) {
        guard !stopped else { return ([], SessionStats(segments: 0, droppedWindows: 0)) }
        stopped = true

        stopLevelsTimer()
        micCapture.stop()
        systemTap.stop()
        prepareTask?.cancel()

        // Drain final partial windows through the ASR.
        await meTranscriber?.finish()
        await themTranscriber?.finish()

        var audio: [AudioFileInfo] = []
        if let meWriter { audio.append(meWriter.finalize()) }
        if let themWriter { audio.append(themWriter.finalize()) }

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

    static func bufferRmsDbfs(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -120 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sum: Double = 0
        if buffer.format.isInterleaved {
            let ptr = data[0]
            for i in 0..<(frames * channels) {
                let s = Double(ptr[i])
                sum += s * s
            }
            sum /= Double(channels)
        } else {
            for ch in 0..<channels {
                let ptr = data[ch]
                for i in 0..<frames {
                    let s = Double(ptr[i])
                    sum += s * s
                }
            }
            sum /= Double(channels)
        }
        let rms = (sum / Double(frames)).squareRoot()
        guard rms > 0 else { return -120 }
        return max(-120, 20 * log10(rms))
    }
}
