import Foundation

/// One recognized token/word with timing relative to the transcribed window.
public struct AsrTokenTiming: Sendable, Equatable {
    public var token: String
    public var startS: Double
    public var endS: Double
    public var confidence: Double

    public init(token: String, startS: Double, endS: Double, confidence: Double) {
        self.token = token
        self.startS = startS
        self.endS = endS
        self.confidence = confidence
    }
}

public struct AsrResult: Sendable, Equatable {
    public var text: String
    /// 0..1; -1 if the engine doesn't report confidence.
    public var confidence: Double
    /// Token timings relative to the window start; empty if unavailable.
    public var tokenTimings: [AsrTokenTiming]

    public init(text: String, confidence: Double, tokenTimings: [AsrTokenTiming] = []) {
        self.text = text
        self.confidence = confidence
        self.tokenTimings = tokenTimings
    }
}

/// Seam for ASR engines (FluidAudio/Parakeet now; WhisperKit fallback later).
public protocol AsrEngine: Sendable {
    /// Engine id as it appears on the wire, e.g. "parakeet-tdt-v3".
    var id: String { get }

    /// Downloads/compiles/loads models. `progress(pct 0..1, stage)` where stage
    /// is "downloading" or "compiling". Idempotent.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws

    /// Transcribes one window of mono Float32 samples at `sampleRate` Hz
    /// (16 kHz for FluidAudio). Implementations must tolerate concurrent
    /// callers (serialize internally if needed).
    func transcribe(window: [Float], sampleRate: Int) async throws -> AsrResult
}
