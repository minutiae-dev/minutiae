import Accelerate
import AVFoundation
import Foundation
@testable import EngineCore

// MARK: - Process metrics

/// Snapshot of this process's resource usage, for before/after comparisons in
/// the load and soak tests.
struct ProcMetrics {
    var cpuSeconds: Double
    /// Phys-footprint — what Activity Monitor shows as "Memory".
    var footprintBytes: UInt64
    var wallClock: Double

    static func sample() -> ProcMetrics {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
               + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return ProcMetrics(cpuSeconds: cpu,
                           footprintBytes: Self.footprint(),
                           wallClock: CFAbsoluteTimeGetCurrent())
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    func delta(since start: ProcMetrics) -> (cpu: Double, wall: Double, footprintDelta: Int64) {
        (cpu: cpuSeconds - start.cpuSeconds,
         wall: wallClock - start.wallClock,
         footprintDelta: Int64(footprintBytes) - Int64(start.footprintBytes))
    }
}

// MARK: - Synthetic audio

/// Deterministic speech-like signal generator. Not speech — but it has the
/// syllable-rate envelope the echo analyzer correlates on, harmonic structure
/// across the analysis bands, and a level that clears the −50 dBFS ASR gate.
///
/// One 10 s period is precomputed and then tiled. Every component frequency
/// divides 10 s exactly, so the loop is seamless — and, more importantly, the
/// benchmark then measures the pipeline instead of the harness's own `sin`
/// calls, which otherwise dominated the profile.
struct SyntheticSpeech {
    static let periodSeconds = 10.0

    let sampleRate: Double
    private let table: [Float]
    private let dither: [Float]
    private var ditherPhase = 0

    init(sampleRate: Double, seed: UInt64 = 0x5EED) {
        self.sampleRate = sampleRate
        var rng = seed
        func noise() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(rng >> 11) / Double(1 << 53)) * 2 - 1
        }
        let n = Int(Self.periodSeconds * sampleRate)
        var t = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let time = Double(i) / sampleRate
            let syll = max(0, sin(2 * .pi * 4 * time))          // 4 Hz syllables
            let word = (Int(time * 0.8) % 4 == 3) ? 0.05 : 1.0   // ~1.25 s pause per 5 s
            let f0 = 110.0 + 25 * sin(2 * .pi * 0.8 * time)      // 0.8 Hz vibrato
            var s = 0.0
            for h in 1...6 { s += sin(2 * .pi * f0 * Double(h) * time) / Double(h) }
            t[i] = Float(s * 0.12 * syll * word) + noise() * 0.002
        }
        self.table = t
        // Real rooms are never digitally silent: −78 dBFS of dither, well under
        // the gate. Digital zero would be an unrealistically easy test.
        self.dither = (0..<4096).map { _ in noise() * 1.2e-4 }
    }

    /// `t` is absolute session time of the first sample.
    mutating func render(into out: inout [Float], startTime t: Double, speaking: Bool) {
        guard speaking else {
            for i in 0..<out.count {
                out[i] = dither[(ditherPhase + i) % dither.count]
            }
            ditherPhase = (ditherPhase + out.count) % dither.count
            return
        }
        let period = table.count
        var idx = Int((t * sampleRate).rounded()) % period
        if idx < 0 { idx += period }
        for i in 0..<out.count {
            out[i] = table[idx]
            idx += 1
            if idx == period { idx = 0 }
        }
    }
}

// MARK: - Session harness

/// Drives the real capture pipeline with synthetic audio at faster than
/// realtime, so a multi-minute session can be measured in seconds.
///
/// MIRRORS `CaptureSession.handle(buffer:hostTime:channel:)` — writers, the two
/// analysis resamplers, the echo analyzer, the delay line and the two ASR
/// resamplers/transcribers, wired in the same order. Keep the two in sync; the
/// bench is worthless if it stops exercising the shipping path.
final class SyntheticSession {
    struct Config {
        var micRate: Double = 48_000
        var micFrames: Int = 4096            // AVAudioEngine tap default
        var tapRate: Double = 48_000
        var tapFrames: Int = 512             // device IO buffer
        var tapChannels: AVAudioChannelCount = 2
        var tapInterleaved = true
        /// Alternating (speaking, silent) seconds.
        var speakSeconds: Double = 20
        var silentSeconds: Double = 40
        var echoGain: Float = 0.35
        var echoDelay: Double = 0.075
        var keepRawMe = false
        /// The system tap's IOProc does not run while the output device is
        /// idle, so `them` buffers can start arbitrarily late into a session.
        var themStartDelay: Double = 0
        /// A mid-session stretch where the tap stops delivering entirely.
        var themGap: ClosedRange<Double>?
    }

    let dir: URL
    let config: Config
    let engine: AsrEngine
    private(set) var meWriter: AudioFileWriter!
    private(set) var themWriter: AudioFileWriter!
    private(set) var meTranscriber: WindowedTranscriber!
    private(set) var themTranscriber: WindowedTranscriber!
    private(set) var analyzer: EchoAnalyzer?
    private(set) var pipeline: DelayedMicPipeline?
    let timeline = GainTimeline()
    let collected = SegmentCollector()

    private let micFormat: AVAudioFormat
    private let tapFormat: AVAudioFormat
    private var meResampler: Resampler!
    private var themResampler: Resampler!
    private var meAnalysis: Resampler!
    private var themAnalysis: Resampler!
    private var micSource: SyntheticSpeech
    private var tapSource: SyntheticSpeech
    /// Ring of far-end history for the acoustic echo path into the mic.
    private var echoTail: [Float]

    init(dir: URL, config: Config = Config(), engine: AsrEngine, suppress: Bool = true) throws {
        self.dir = dir
        self.config = config
        self.engine = engine
        self.micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: config.micRate,
                                       channels: 1, interleaved: false)!
        self.tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: config.tapRate,
                                       channels: config.tapChannels,
                                       interleaved: config.tapInterleaved)!
        self.micSource = SyntheticSpeech(sampleRate: config.micRate, seed: 0xA11CE)
        self.tapSource = SyntheticSpeech(sampleRate: config.tapRate, seed: 0xB0B)
        self.echoTail = [Float](repeating: 0, count: Int(config.echoDelay * config.micRate) + 1)

        meWriter = try AudioFileWriter(channel: .me, dir: dir, format: micFormat)
        themWriter = try AudioFileWriter(channel: .them, dir: dir, format: tapFormat)
        meResampler = Resampler(inputFormat: micFormat)
        themResampler = Resampler(inputFormat: tapFormat)
        if suppress {
            meAnalysis = Resampler(inputFormat: micFormat)
            themAnalysis = Resampler(inputFormat: tapFormat)
            analyzer = EchoAnalyzer(timeline: timeline)
            pipeline = DelayedMicPipeline(timeline: timeline, format: micFormat)
        }
        let allocator = SegmentIndexAllocator()
        let sink = collected
        meTranscriber = WindowedTranscriber(channel: .me, engine: engine,
                                            indexAllocator: allocator) { sink.append($0) }
        themTranscriber = WindowedTranscriber(channel: .them, engine: engine,
                                              indexAllocator: allocator) { sink.append($0) }
    }

    func speaking(at t: Double) -> Bool {
        let period = config.speakSeconds + config.silentSeconds
        guard period > 0 else { return true }
        return t.truncatingRemainder(dividingBy: period) < config.speakSeconds
    }

    /// Runs `seconds` of synthetic session time.
    ///
    /// Buffers are pushed as fast as the machine can, which is ~60x realtime.
    /// The writers' background Opus encoders are ~120x realtime, so left alone
    /// they would fall behind and trip their backlog guard — measuring the
    /// fallback transcode instead of what a real session does. Pacing them once
    /// every 10 simulated seconds — comfortably inside the guard's 30 s window
    /// — keeps the benchmark on the shipping path.
    func run(seconds: Double) {
        var nextEncoderSync = 10.0
        var micTime = 0.0
        var tapTime = 0.0
        let micStep = Double(config.micFrames) / config.micRate
        let tapStep = Double(config.tapFrames) / config.tapRate
        var mic = [Float](repeating: 0, count: config.micFrames)
        var tapMono = [Float](repeating: 0, count: config.tapFrames)

        while micTime < seconds || tapTime < seconds {
            // Interleave the two callbacks in time order, as Core Audio does.
            if tapTime <= micTime {
                if tapTime >= config.themStartDelay && !(config.themGap?.contains(tapTime) ?? false) {
                    tapSource.render(into: &tapMono, startTime: tapTime, speaking: speaking(at: tapTime))
                    feedThem(tapMono, at: tapTime)
                }
                tapTime += tapStep
            } else {
                micSource.render(into: &mic, startTime: micTime, speaking: speaking(at: micTime))
                addEcho(into: &mic)
                feedMe(mic, at: micTime)
                micTime += micStep
            }
            if micTime > nextEncoderSync {
                meWriter.waitForEncoder()
                themWriter.waitForEncoder()
                nextEncoderSync += 10
            }
        }
    }

    /// Acoustic path: the far end reaches the mic delayed and attenuated.
    private var farHistory: [Float] = []
    private func addEcho(into mic: inout [Float]) {
        let delaySamples = echoTail.count - 1
        guard farHistory.count >= mic.count + delaySamples else {
            farHistory.removeAll(keepingCapacity: true)
            return
        }
        let start = farHistory.count - mic.count - delaySamples
        for i in 0..<mic.count {
            mic[i] += farHistory[start + i] * config.echoGain
        }
        // Keep only what the delay needs.
        if farHistory.count > delaySamples + 4 * mic.count {
            farHistory.removeFirst(farHistory.count - delaySamples - 2 * mic.count)
        }
    }

    private func feedThem(_ mono: [Float], at t: Double) {
        farHistory.append(contentsOf: mono)
        let buf = AVAudioPCMBuffer(pcmFormat: tapFormat,
                                   frameCapacity: AVAudioFrameCount(mono.count))!
        buf.frameLength = AVAudioFrameCount(mono.count)
        let d = buf.floatChannelData!
        let ch = Int(tapFormat.channelCount)
        if tapFormat.isInterleaved {
            for i in 0..<mono.count {
                for c in 0..<ch { d[0][i * ch + c] = mono[i] }
            }
        } else {
            for c in 0..<ch { for i in 0..<mono.count { d[c][i] = mono[i] } }
        }

        _ = CaptureSession.bufferRmsDbfs(buf)
        themWriter.write(buf, at: t)
        if let themAnalysis, let analyzer {
            let ref = themAnalysis.convert(buf)
            if !ref.isEmpty { analyzer.pushFar(ref, at: t) }
        }
        let samples = themResampler.convert(buf)
        if !samples.isEmpty { themTranscriber.feed(samples: samples, firstSampleTime: t) }
    }

    private func feedMe(_ mono: [Float], at t: Double) {
        let buf = AVAudioPCMBuffer(pcmFormat: micFormat,
                                   frameCapacity: AVAudioFrameCount(mono.count))!
        buf.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }

        _ = CaptureSession.bufferRmsDbfs(buf)
        guard let analyzer, let pipeline, let meAnalysis else {
            emitMe(buf, at: t)
            return
        }
        let near = meAnalysis.convert(buf)
        if !near.isEmpty { analyzer.pushNear(near, at: t) }
        pipeline.enqueue(buf, t0: t)
        pipeline.flushReady(now: t) { [weak self] gained, t0 in self?.emitMe(gained, at: t0) }
    }

    private func emitMe(_ buf: AVAudioPCMBuffer, at t: Double) {
        meWriter.write(buf, at: t)
        let samples = meResampler.convert(buf)
        if !samples.isEmpty { meTranscriber.feed(samples: samples, firstSampleTime: t) }
    }

    /// Mirrors CaptureSession.stop()'s ordering.
    func finish(at endTime: Double? = nil) async -> [AudioFileInfo] {
        pipeline?.drainAll { [weak self] gained, t0 in self?.emitMe(gained, at: t0) }
        await meTranscriber.finish()
        await themTranscriber.finish()
        return [meWriter.finalize(at: endTime), themWriter.finalize(at: endTime)]
    }

    /// Total bytes currently on disk under the session dir.
    func bytesOnDisk() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Int64(size)
        }
    }
}

/// ASR stand-in that records how much audio it was asked to transcribe, so
/// tests can assert the silence gate actually kept work off the engine.
final class CountingAsrEngine: AsrEngine, @unchecked Sendable {
    let id = "counting-engine"
    private let lock = NSLock()
    private var _calls = 0
    private var _samples = 0
    private let text: String
    /// Simulated per-window cost, to model a real engine's serialization.
    private let costSeconds: Double

    init(text: String = "one two three four five", costSeconds: Double = 0) {
        self.text = text
        self.costSeconds = costSeconds
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var samplesSeen: Int { lock.lock(); defer { lock.unlock() }; return _samples }

    /// Flipped by tests that simulate a model still loading.
    private var _ready = true
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return _ready }
    func setReady(_ v: Bool) { lock.lock(); _ready = v; lock.unlock() }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        setReady(true)
    }

    func makeContext() -> AsrContext { StatelessAsrContext() }

    /// Unique per call — a stub that returned the same words every window
    /// would be fully eaten by the overlap de-dup and hide real behaviour.
    private func record(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        _samples += n
        return "\(text) w\(_calls)"
    }

    func transcribe(window: [Float], sampleRate: Int, context: AsrContext) async throws -> AsrResult {
        let reply = record(window.count)
        if costSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(costSeconds * 1e9)) }
        return AsrResult(text: reply, confidence: 0.9)
    }
}
