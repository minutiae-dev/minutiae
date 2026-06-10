import AVFoundation
import Foundation

/// Per-channel audio persistence. During capture, buffers append to
/// `audio-<ch>.wav.part` (native format, crash-safe). On finalize, the WAV is
/// transcoded to Opus-in-CAF `audio-<ch>.caf` (Apple's Opus encoder won't mux
/// Ogg). If the Opus transcode fails, the WAV is kept and reported honestly as
/// codec "pcm" / container "wav" — metadata is never faked.
public final class AudioFileWriter: @unchecked Sendable {
    public let channel: Channel
    private let dir: URL
    private let format: AVAudioFormat
    private let partURL: URL
    private var file: AVAudioFile?
    private var framesWritten: Int64 = 0
    private let lock = NSLock()

    public init(channel: Channel, dir: URL, format: AVAudioFormat) throws {
        self.channel = channel
        self.dir = dir
        self.format = format
        // AVAudioFile infers the container from the path extension, so the
        // crash-safe part file is named "audio-<ch>.part.wav" (".wav" last).
        self.partURL = dir.appendingPathComponent("audio-\(channel.rawValue).part.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: partURL, settings: settings,
                               commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    }

    /// Called from the capture callback queue.
    public func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        do {
            try file.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
        } catch {
            log("audio write failed (\(channel.rawValue)): \(error.localizedDescription)")
        }
    }

    public var durationSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(framesWritten) / format.sampleRate
    }

    /// Closes the part file, transcodes to Opus/CAF, deletes the part on
    /// success. Returns honest metadata either way.
    public func finalize() -> AudioFileInfo {
        lock.lock()
        file = nil // closes the AVAudioFile
        let frames = framesWritten
        lock.unlock()

        let duration = Double(frames) / format.sampleRate
        let cafURL = dir.appendingPathComponent("audio-\(channel.rawValue).caf")

        do {
            try transcodeToOpusCAF(from: partURL, to: cafURL)
            try? FileManager.default.removeItem(at: partURL)
            return AudioFileInfo(channel: channel, path: cafURL.path,
                                 codec: "opus", container: "caf",
                                 durationS: duration, sampleRate: format.sampleRate)
        } catch {
            log("opus transcode failed (\(channel.rawValue)): \(error.localizedDescription) — keeping WAV")
            // Keep the PCM data; rename .part.wav → .wav and report honestly.
            let wavURL = dir.appendingPathComponent("audio-\(channel.rawValue).wav")
            do {
                try? FileManager.default.removeItem(at: wavURL)
                try FileManager.default.moveItem(at: partURL, to: wavURL)
                return AudioFileInfo(channel: channel, path: wavURL.path,
                                     codec: "pcm", container: "wav",
                                     durationS: duration, sampleRate: format.sampleRate)
            } catch {
                return AudioFileInfo(channel: channel, path: partURL.path,
                                     codec: "pcm", container: "wav",
                                     durationS: duration, sampleRate: format.sampleRate)
            }
        }
    }

    private func transcodeToOpusCAF(from src: URL, to dst: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let inFormat = input.processingFormat

        // Opus supports specific rates; pick the nearest supported rate ≥ the
        // capture rate (capped at 48 k). Opus in CoreAudio: 8/12/16/24/48 kHz.
        let supported: [Double] = [8000, 12000, 16000, 24000, 48000]
        let opusRate = supported.first(where: { $0 >= inFormat.sampleRate }) ?? 48000
        let channels = min(inFormat.channelCount, 2)

        try? FileManager.default.removeItem(at: dst)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: opusRate,
            AVNumberOfChannelsKey: channels,
        ]
        let output = try AVAudioFile(forWriting: dst, settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        // AVAudioFile encodes on write when the file's processing format
        // differs from its file format; feed it PCM at the Opus rate.
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
