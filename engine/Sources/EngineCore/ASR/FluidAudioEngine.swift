import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT v3 on the Apple Neural Engine via FluidAudio (pinned exact in
/// Package.swift — 0.x API churn). One shared instance serves both channels;
/// AsrManager is an actor, so transcribe calls serialize through it.
public final class FluidAudioEngine: AsrEngine, @unchecked Sendable {
    public let id = "parakeet-tdt-v3"
    /// Reported in hello_ack engine_versions (FluidAudio package revision).
    public static let version = "0.15.2"

    private let manager = AsrManager(config: .default)
    private let language: Language?

    private struct PrepState {
        var prepared = false
        var preparing: Task<Void, Error>?
    }
    private let prepareLock = NSLock()
    private var prepState = PrepState()

    private func withPrepState<R>(_ body: (inout PrepState) -> R) -> R {
        prepareLock.lock(); defer { prepareLock.unlock() }
        return body(&prepState)
    }

    public init(language: String = "en") {
        self.language = Language(rawValue: language)
    }

    /// True if the Parakeet v3 CoreML models are already in the local cache —
    /// drives `models_ready` in hello_ack without touching the network.
    public static func modelsCached() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    /// Downloads (if needed), compiles and loads the models. Idempotent and
    /// coalesces concurrent callers into one underlying task.
    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let manager = self.manager
        let task: Task<Void, Error>? = withPrepState { state in
            if state.prepared { return nil }
            if let existing = state.preparing { return existing }
            let task = Task {
                let models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    progressHandler: { p in
                        let stage: String
                        switch p.phase {
                        case .listing, .downloading: stage = "downloading"
                        case .compiling: stage = "compiling"
                        }
                        progress(p.fractionCompleted, stage)
                    })
                try await manager.loadModels(models)
            }
            state.preparing = task
            return task
        }
        guard let task else { return }
        do {
            try await task.value
            withPrepState { $0.prepared = true }
        } catch {
            withPrepState { $0.preparing = nil }
            throw error
        }
    }

    /// Stateless per-window transcription (fresh decoder state per call —
    /// batch-mode per 5 s window; overlap de-dup happens upstream).
    public func transcribe(window: [Float], sampleRate: Int) async throws -> AsrResult {
        guard sampleRate == Int(Resampler.asrSampleRate) else {
            throw CaptureError.internalError("FluidAudioEngine requires 16 kHz input, got \(sampleRate)")
        }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(window, decoderState: &state, language: language)
        let timings: [AsrTokenTiming] = (result.tokenTimings ?? []).map {
            AsrTokenTiming(token: $0.token, startS: $0.startTime, endS: $0.endTime,
                           confidence: Double($0.confidence))
        }
        return AsrResult(text: result.text,
                         confidence: Double(result.confidence),
                         tokenTimings: timings)
    }
}
