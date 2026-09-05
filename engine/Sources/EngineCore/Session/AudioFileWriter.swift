import Accelerate
import AVFoundation
import Foundation

/// Per-channel audio persistence.
///
/// Two files exist during a session:
///
///  - `audio-<ch>.part.wav` — mono 16-bit PCM at the capture rate, appended
///    synchronously from the capture callback. This is the crash-safe copy: a
///    truncated WAV still holds every sample that was written.
///  - `audio-<ch>.caf` — Opus, encoded INCREMENTALLY on a background queue as
///    the session runs. Opus in CAF is not crash-safe (the packet table is only
///    written on close), which is exactly why the WAV exists alongside it.
///
/// On `finalize()` the encoder drains its (sub-second) backlog, the CAF closes,
/// and the WAV is deleted. If anything about the Opus path failed, the whole
/// file is transcoded at finalize instead; if that fails too, the WAV is kept
/// and reported honestly as codec "pcm" / container "wav" — metadata is never
/// faked.
///
/// Both files are SESSION-TIME ALIGNED: sample 0 is session time zero. A
/// capture source that has not started yet delivers nothing — the system tap's
/// IOProc does not run while the output device is idle — so the writer pads
/// silence for the time it was absent. Without that the file's first sample is
/// whenever the first sound happened, the two channels drift apart by however
/// long the meeting was quiet, and every transcript timestamp points at the
/// wrong place in the recording.
///
/// Why the recording is persisted mono, 16-bit, at the native rate:
///
///  - Mono because both channels are speech destined for a transcript. The
///    system tap is a stereo mix of remote participants that carries no spatial
///    information worth keeping, and the ASR feed has always been mono anyway.
///  - 16-bit because the artifact is lossy Opus in the end; float32 PCM only
///    ever existed as an intermediate.
///  - Native sample rate, because forcing a rate on a capture source is the one
///    thing this codebase will not do (AirPods deliver 16/24 kHz).
///
/// Together those take the in-session scratch file from 1.93 GB/h to 0.64 GB/h,
/// which is also the largest single CPU cost in the capture path — it is
/// dominated by `pwrite`.
public final class AudioFileWriter: @unchecked Sendable {
    /// The recording is encoded at 16 kHz — the same rate the ASR consumes, so
    /// re-transcribing an archived session feeds the model exactly the input it
    /// had live. 8 kHz of audio bandwidth is wideband speech, better than any
    /// VoIP source the `them` tap will ever carry.
    ///
    /// This is also the cheapest point on the measured curve, per 10 min of
    /// mono audio: 48 kHz costs 2.1 s to encode and 18 MB/h, 24 kHz costs 4.4 s
    /// and 11 MB/h, 16 kHz costs 3.6 s and 7 MB/h. 16 kHz dominates 24 kHz on
    /// both axes and beats 48 kHz 2.5× on size for half a second of background
    /// CPU per ten minutes.
    ///
    /// Capture is untouched — this caps only what is persisted, and it never
    /// upsamples: a 16 kHz AirPods mic is still stored at its native rate.
    public static let maxOpusSampleRate: Double = 16_000
    /// Set explicitly rather than left to CoreAudio's default, which currently
    /// picks the same value at 16 kHz but is not contractual.
    public static let opusBitRate = 16_000
    /// Audio is handed to the encoder in chunks of about this length, so the
    /// background queue is woken once a second rather than per capture buffer.
    static let encodeChunkSeconds = 1.0
    /// Safety valve. The encoder runs ~120× realtime so its backlog is normally
    /// one chunk, but an unbounded queue is an unbounded memory leak in a long
    /// meeting. If it ever gets this far behind we stop feeding it and fall
    /// back to transcoding the (complete) scratch WAV at stop.
    static let maxQueuedEncodeSeconds = 30.0

    public let channel: Channel
    private let dir: URL
    /// The CAPTURE format — reported in metadata and used for duration math.
    private let format: AVAudioFormat
    /// What the part file accepts: mono float32 at the capture rate. Buffers
    /// that already match are written without a copy.
    private let writeFormat: AVAudioFormat
    private let nameSuffix: String
    private let partURL: URL
    private let cafURL: URL

    /// A source is treated as having stopped when its next buffer starts this
    /// far after the previous one ended. An IO buffer is 10-90 ms and host-time
    /// jitter is sub-millisecond; comparing CONSECUTIVE buffers (rather than
    /// session time against a running frame count) means clock drift over an
    /// hour can never accumulate into a spurious pad.
    static let gapThresholdSeconds = 0.25

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: Int64 = 0
    /// Session seconds covered by what has been written so far. Starts at zero:
    /// a source that first delivers at t = 9.3 s owes 9.3 s of silence.
    private var writtenThrough: Double = 0
    /// Reused silence source for padding; grown on demand, never per gap.
    private var silenceScratch: AVAudioPCMBuffer?
    private var loggedPad = false
    /// Reused mono downmix target; grown on demand, never per buffer.
    private var monoScratch: AVAudioPCMBuffer?
    /// Accumulates mono audio until it is worth waking the encoder.
    private var pending: AVAudioPCMBuffer?
    /// Frames handed to `encodeQueue` and not yet encoded.
    private var queuedEncodeFrames: Int64 = 0
    /// Set if the backlog ever blew past the cap; forces the transcode path.
    private var encoderOverran = false

    /// Everything below is touched ONLY on `encodeQueue`.
    private let encodeQueue: DispatchQueue
    private var opusFile: AVAudioFile?
    private var opusConverter: AVAudioConverter?
    private var opusFormat: AVAudioFormat?
    private var opusBroken = false

    /// `nameSuffix` distinguishes side-car recordings of the same channel
    /// (the debug raw-mic capture writes "audio-me-raw"). Empty for the real
    /// channel file.
    public init(channel: Channel, dir: URL, format: AVAudioFormat, nameSuffix: String = "") throws {
        self.channel = channel
        self.dir = dir
        self.format = format
        self.nameSuffix = nameSuffix
        // AVAudioFile infers the container from the path extension, so the
        // crash-safe part file is named "audio-<ch>.part.wav" (".wav" last).
        self.partURL = dir.appendingPathComponent("audio-\(channel.rawValue)\(nameSuffix).part.wav")
        self.cafURL = dir.appendingPathComponent("audio-\(channel.rawValue)\(nameSuffix).caf")
        self.encodeQueue = DispatchQueue(
            label: "com.minutiae.engine.opus.\(channel.rawValue)\(nameSuffix)", qos: .utility)
        guard let writeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: format.sampleRate,
                                              channels: 1, interleaved: false) else {
            throw CaptureError.internalError("could not build mono write format")
        }
        self.writeFormat = writeFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // File format is 16-bit int; the processing format stays float32 mono,
        // so AVAudioFile does the narrowing on write and callers keep handing
        // us the float buffers the capture path already has.
        file = try AVAudioFile(forWriting: partURL, settings: settings,
                               commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    }

    // MARK: - Capture path

    /// Called from the capture callback queue.
    ///
    /// `time` is the session-relative time of the buffer's first sample. When
    /// it is given, silence is inserted for any stretch the source did not
    /// deliver, so the file stays aligned to the session clock.
    public func write(_ buffer: AVAudioPCMBuffer, at time: Double? = nil) {
        guard buffer.frameLength > 0 else { return }
        var chunks: [AVAudioPCMBuffer] = []
        lock.lock()
        if let time { padLocked(upTo: time, into: &chunks) }
        var chunk: AVAudioPCMBuffer?
        if let file, let mono = monoBuffer(for: buffer) {
            do {
                try file.write(from: mono)
                framesWritten += Int64(mono.frameLength)
            } catch {
                log("audio write failed (\(channel.rawValue)): \(error.localizedDescription)")
            }
            chunk = accumulate(mono)
            if let ready = takeChunkLocked(chunk) { chunks.append(ready) }
            if let time {
                // Never move backwards: a buffer stamped slightly early (or
                // out of order) must not make the next one look like a gap.
                writtenThrough = max(writtenThrough,
                                     time + Double(mono.frameLength) / format.sampleRate)
            }
        }
        lock.unlock()
        for chunk in chunks { submit(chunk) }
    }

    /// Applies the encoder-backlog guard to a ready chunk. Caller holds `lock`.
    private func takeChunkLocked(_ chunk: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let ready = chunk else { return nil }
        if queuedEncodeFrames > Int64(Self.maxQueuedEncodeSeconds * format.sampleRate) {
            // Stop feeding it rather than growing the queue forever.
            // The WAV still holds every sample, so nothing is lost.
            if !encoderOverran {
                encoderOverran = true
                log("opus encoder fell behind (\(channel.rawValue)) — transcoding at stop instead")
            }
            return nil
        }
        queuedEncodeFrames += Int64(ready.frameLength)
        return ready
    }

    private func submit(_ chunk: AVAudioPCMBuffer) {
        encodeQueue.async { [weak self] in
            guard let self else { return }
            self.encode(chunk)
            self.lock.lock()
            self.queuedEncodeFrames -= Int64(chunk.frameLength)
            self.lock.unlock()
        }
    }

    /// Writes silence up to session time `time`, through exactly the same path
    /// as audio — the WAV, the incremental Opus stream and `framesWritten` all
    /// have to agree, or the transcode fallback would disagree with the
    /// streamed file about where the audio sits. Caller holds `lock`.
    private func padLocked(upTo time: Double, into chunks: inout [AVAudioPCMBuffer]) {
        let gap = time - writtenThrough
        guard gap >= Self.gapThresholdSeconds, let file else { return }
        var remaining = Int((gap * format.sampleRate).rounded())
        guard remaining > 0 else { return }
        if !loggedPad, gap >= 1.0 {
            loggedPad = true
            log(String(format: "%@ recording: padding %.1f s the source did not deliver",
                       channel.rawValue, gap))
        }
        let chunkFrames = AVAudioFrameCount(format.sampleRate)   // 1 s at a time
        if silenceScratch == nil || silenceScratch!.frameCapacity < chunkFrames {
            silenceScratch = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: chunkFrames)
            if let s = silenceScratch, let d = s.floatChannelData {
                memset(d[0], 0, Int(chunkFrames) * MemoryLayout<Float>.size)
            }
        }
        guard let silence = silenceScratch else { return }
        while remaining > 0 {
            let n = min(remaining, Int(chunkFrames))
            silence.frameLength = AVAudioFrameCount(n)
            do {
                try file.write(from: silence)
                framesWritten += Int64(n)
            } catch {
                log("audio pad failed (\(channel.rawValue)): \(error.localizedDescription)")
                break
            }
            if let ready = takeChunkLocked(accumulate(silence)) { chunks.append(ready) }
            remaining -= n
        }
        writtenThrough = time
    }

    /// Appends `mono` to the encoder accumulator, returning a full chunk to
    /// hand off when one is ready. Caller holds `lock`.
    private func accumulate(_ mono: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let chunkFrames = AVAudioFrameCount(Self.encodeChunkSeconds * format.sampleRate)
        if pending == nil {
            pending = AVAudioPCMBuffer(pcmFormat: writeFormat,
                                       frameCapacity: chunkFrames + mono.frameLength)
            pending?.frameLength = 0
        }
        guard var acc = pending else { return nil }
        if acc.frameLength + mono.frameLength > acc.frameCapacity {
            // A capture buffer larger than the headroom we sized for: grow.
            guard let bigger = AVAudioPCMBuffer(
                pcmFormat: writeFormat,
                frameCapacity: acc.frameLength + mono.frameLength + chunkFrames),
                  let dst = bigger.floatChannelData, let src = acc.floatChannelData else { return nil }
            bigger.frameLength = acc.frameLength
            dst[0].update(from: src[0], count: Int(acc.frameLength))
            pending = bigger
            acc = bigger
        }
        guard let dst = acc.floatChannelData, let src = mono.floatChannelData else { return nil }
        (dst[0] + Int(acc.frameLength)).update(from: src[0], count: Int(mono.frameLength))
        acc.frameLength += mono.frameLength

        guard acc.frameLength >= chunkFrames else { return nil }
        pending = nil
        return acc
    }

    /// Returns `buffer` untouched when it is already mono float32 at the write
    /// format, otherwise downmixes into the reusable scratch buffer.
    private func monoBuffer(for buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.channelCount == 1, buffer.format == writeFormat { return buffer }
        guard let src = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        if monoScratch == nil || monoScratch!.frameCapacity < buffer.frameLength {
            monoScratch = AVAudioPCMBuffer(pcmFormat: writeFormat,
                                           frameCapacity: buffer.frameLength)
        }
        guard let out = monoScratch, let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let d = dst[0]

        var scale = Float(1) / Float(channels)
        if buffer.format.isInterleaved {
            if channels == 2 {
                // The overwhelmingly common tap layout: one strided add.
                vDSP_vasm(src[0], 2, src[0] + 1, 2, &scale, d, 1, vDSP_Length(frames))
                return out
            }
            var unity = Float(1)
            vDSP_vsmul(src[0], vDSP_Stride(channels), &unity, d, 1, vDSP_Length(frames))
            for c in 1..<channels {
                vDSP_vadd(d, 1, src[0] + c, vDSP_Stride(channels), d, 1, vDSP_Length(frames))
            }
        } else {
            d.update(from: src[0], count: frames)
            for c in 1..<channels {
                vDSP_vadd(d, 1, src[c], 1, d, 1, vDSP_Length(frames))
            }
        }
        if channels > 1 {
            vDSP_vsmul(d, 1, &scale, d, 1, vDSP_Length(frames))
        }
        return out
    }

    public var durationSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(framesWritten) / format.sampleRate
    }

    // MARK: - Incremental Opus (encodeQueue only)

    /// Opus supports specific rates; pick the nearest supported rate ≥ the
    /// capture rate, then cap it. Opus in CoreAudio: 8/12/16/24/48 kHz.
    /// The `min` only ever lowers the rate, so a capture below the cap keeps
    /// its native rate.
    private var opusSampleRate: Double {
        let supported: [Double] = [8000, 12000, 16000, 24000, 48000]
        let nearest = supported.first(where: { $0 >= format.sampleRate }) ?? 48000
        return min(nearest, Self.maxOpusSampleRate)
    }

    private func openOpusIfNeeded() -> Bool {
        if opusBroken { return false }
        if opusFile != nil { return true }
        let rate = opusSampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.opusBitRate,
        ]
        do {
            try? FileManager.default.removeItem(at: cafURL)
            opusFile = try AVAudioFile(forWriting: cafURL, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: 1, interleaved: false) else {
                throw CaptureError.internalError("could not build opus pcm format")
            }
            opusFormat = target
            // Only needed when the capture rate is not itself an Opus rate
            // (e.g. 44.1 kHz); otherwise buffers go straight in.
            if rate != format.sampleRate {
                guard let conv = AVAudioConverter(from: writeFormat, to: target) else {
                    throw CaptureError.internalError("could not build opus converter")
                }
                opusConverter = conv
            }
            return true
        } catch {
            log("opus stream open failed (\(channel.rawValue)): \(error.localizedDescription) "
                + "— falling back to transcode at stop")
            markOpusBroken()
            return false
        }
    }

    private func markOpusBroken() {
        opusBroken = true
        opusFile = nil
        opusConverter = nil
        try? FileManager.default.removeItem(at: cafURL)
    }

    private func encode(_ chunk: AVAudioPCMBuffer) {
        guard openOpusIfNeeded(), let opusFile else { return }
        do {
            if let converter = opusConverter, let target = opusFormat {
                let ratio = target.sampleRate / writeFormat.sampleRate
                let capacity = AVAudioFrameCount((Double(chunk.frameLength) * ratio).rounded(.up) + 64)
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                    throw CaptureError.internalError("opus buffer alloc failed")
                }
                var fed = false
                var convError: NSError?
                let status = converter.convert(to: out, error: &convError) { _, s in
                    if fed { s.pointee = .noDataNow; return nil }
                    fed = true
                    s.pointee = .haveData
                    return chunk
                }
                if status == .error { throw convError ?? CaptureError.internalError("opus convert failed") }
                if out.frameLength > 0 { try opusFile.write(from: out) }
            } else {
                try opusFile.write(from: chunk)
            }
        } catch {
            log("opus stream write failed (\(channel.rawValue)): \(error.localizedDescription) "
                + "— falling back to transcode at stop")
            markOpusBroken()
        }
    }

    /// Blocks until the background encoder has caught up. Diagnostics and
    /// tests only — `finalize()` already does this as part of closing.
    func waitForEncoder() {
        encodeQueue.sync {}
    }

    // MARK: - Finalize

    /// Closes both files. Returns honest metadata for whichever survived.
    ///
    /// `endTime` is the session time recording stopped; when given, a source
    /// that went quiet before the end is padded so both channels span the whole
    /// session. A channel that never delivered anything stays empty — a file of
    /// pure silence would be a lie about a source that was never there.
    public func finalize(at endTime: Double? = nil) -> AudioFileInfo {
        lock.lock()
        if let endTime, framesWritten > 0 {
            var tail: [AVAudioPCMBuffer] = []
            padLocked(upTo: endTime, into: &tail)
            for chunk in tail { submit(chunk) }
        }
        file = nil // closes the AVAudioFile
        let frames = framesWritten
        let tail = pending
        let overran = encoderOverran
        pending = nil
        monoScratch = nil
        lock.unlock()

        let duration = Double(frames) / format.sampleRate

        // Drain the encoder's backlog (well under a second of audio) and close.
        var streamed = false
        encodeQueue.sync {
            if overran {
                markOpusBroken()
            } else {
                if let tail, tail.frameLength > 0 { encode(tail) }
                streamed = !opusBroken && opusFile != nil
            }
            opusFile = nil
            opusConverter = nil
        }

        if streamed, FileManager.default.fileExists(atPath: cafURL.path) {
            try? FileManager.default.removeItem(at: partURL)
            return AudioFileInfo(channel: channel, path: cafURL.path,
                                 codec: "opus", container: "caf",
                                 durationS: duration, sampleRate: opusSampleRate,
                                 sourceSampleRate: format.sampleRate)
        }

        // Incremental encoding never got off the ground (or broke mid-session).
        // Fall back to transcoding the whole part file in one go.
        if frames > 0 {
            do {
                try transcodeToOpusCAF(from: partURL, to: cafURL)
                try? FileManager.default.removeItem(at: partURL)
                return AudioFileInfo(channel: channel, path: cafURL.path,
                                     codec: "opus", container: "caf",
                                     durationS: duration, sampleRate: opusSampleRate,
                                     sourceSampleRate: format.sampleRate)
            } catch {
                log("opus transcode failed (\(channel.rawValue)): \(error.localizedDescription) — keeping WAV")
            }
        }

        // Keep the PCM data; rename .part.wav → .wav and report honestly.
        let wavURL = dir.appendingPathComponent("audio-\(channel.rawValue)\(nameSuffix).wav")
        do {
            try? FileManager.default.removeItem(at: wavURL)
            try FileManager.default.moveItem(at: partURL, to: wavURL)
            return AudioFileInfo(channel: channel, path: wavURL.path,
                                 codec: "pcm", container: "wav",
                                 durationS: duration, sampleRate: format.sampleRate,
                                 sourceSampleRate: format.sampleRate)
        } catch {
            return AudioFileInfo(channel: channel, path: partURL.path,
                                 codec: "pcm", container: "wav",
                                 durationS: duration, sampleRate: format.sampleRate,
                                 sourceSampleRate: format.sampleRate)
        }
    }

    /// Whole-file fallback, used only when the incremental encoder failed.
    private func transcodeToOpusCAF(from src: URL, to dst: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let inFormat = input.processingFormat
        let opusRate = opusSampleRate
        let channels = AVAudioChannelCount(1)   // the part file is already mono

        try? FileManager.default.removeItem(at: dst)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: opusRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: Self.opusBitRate,
        ]
        let output = try AVAudioFile(forWriting: dst, settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        guard let pcmAtOpusRate = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: opusRate,
                                                channels: channels,
                                                interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: pcmAtOpusRate) else {
            throw CaptureError.internalError("could not build converter for opus transcode")
        }

        let chunkFrames: AVAudioFrameCount = 32_768
        var reachedEnd = false
        while true {
            let outCapacity = AVAudioFrameCount(Double(chunkFrames) * (opusRate / inFormat.sampleRate) + 64)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcmAtOpusRate, frameCapacity: outCapacity) else {
                throw CaptureError.internalError("buffer alloc failed during transcode")
            }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames) else {
                    outStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                do {
                    try input.read(into: inBuf, frameCount: chunkFrames)
                } catch {
                    outStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                if inBuf.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error {
                throw convError ?? CaptureError.internalError("conversion failed during transcode")
            }
            if outBuf.frameLength > 0 {
                try output.write(from: outBuf)
            }
            if status == .endOfStream { break }
        }
    }
}
