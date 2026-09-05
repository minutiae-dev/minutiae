import AVFoundation

/// AVAudioConverter wrapper: any input format → 16 kHz mono Float32 for the
/// ASR feed. Recorded audio keeps the native rate; only the ASR feed resamples.
public final class Resampler {
    public static let asrSampleRate: Double = 16_000

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    public let inputFormat: AVAudioFormat
    /// Reused output buffer, grown on demand. Allocating (and freeing) an
    /// AVAudioPCMBuffer per capture callback was ~20% of this function's cost.
    /// NOT thread-safe — same as the underlying AVAudioConverter, which already
    /// requires each instance to be driven from one place at a time.
    private var output: AVAudioPCMBuffer?

    public init?(inputFormat: AVAudioFormat) {
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Self.asrSampleRate,
                                            channels: 1,
                                            interleaved: false),
              let conv = AVAudioConverter(from: inputFormat, to: outFormat)
        else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outFormat
        self.converter = conv
    }

    /// Converts one buffer; returns 16 kHz mono Float32 samples (possibly empty
    /// while the converter primes). Streaming-safe: converter state carries over.
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Self.asrSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard capacity > 0 else { return [] }
        if output == nil || output!.frameCapacity < capacity {
            output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let out = output else { return [] }
        out.frameLength = 0

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            log("resampler error: \(convError?.localizedDescription ?? "unknown")")
            return []
        }
        guard out.frameLength > 0, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
