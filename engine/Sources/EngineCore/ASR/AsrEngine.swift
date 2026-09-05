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

/// Per-channel decoding state carried between windows.
///
/// Parakeet's TDT decoder is a predictor LSTM plus a last-token context: feeding
/// window N+1 with the state window N ended in keeps the language model
/// continuous across a cut, which is what lets `WindowedTranscriber` cut at
/// pauses instead of paying for overlapping windows. The `me` and `them`
/// channels are different speakers on one engine, so each owns its own context —
/// never share one between channels.
///
/// Engines with nothing to carry (Nemotron resets per window) return a no-op.
public protocol AsrContext: AnyObject, Sendable {
    /// Drop the carried context: a long silence, a capture gap, or a failed
    /// decode all mean the next window does not continue this sentence.
    func reset()
}

/// Context for engines that carry nothing between windows.
public final class StatelessAsrContext: AsrContext {
    public init() {}
    public func reset() {}
}

/// Seam for ASR engines (FluidAudio/Parakeet now; WhisperKit fallback later).
public protocol AsrEngine: Sendable {
    /// Engine id as it appears on the wire, e.g. "parakeet-tdt-v3".
    var id: String { get }

    /// True once `prepare()` has fully loaded the models. `transcribe` before
    /// this throws; `WindowedTranscriber` holds audio in its ring rather than
    /// dropping windows while this is false.
    var isReady: Bool { get }

    /// Downloads/compiles/loads models. `progress(pct 0..1, stage)` where stage
    /// is "downloading" or "compiling". Idempotent, and awaiting it a second
    /// time is the way to wait for an in-flight prepare.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws

    /// A fresh decoding context. One per channel, for the lifetime of a session.
    func makeContext() -> AsrContext

    /// Transcribes one window of mono Float32 samples at `sampleRate` Hz
    /// (16 kHz for FluidAudio), updating `context` in place. Implementations
    /// must tolerate concurrent callers (serialize internally if needed).
    func transcribe(window: [Float], sampleRate: Int, context: AsrContext) async throws -> AsrResult
}
