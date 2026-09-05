import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 on the Apple Neural Engine via FluidAudio
/// (pinned exact in Package.swift — 0.x API churn). The shipped default:
/// multilingual (25 European languages, auto-detected), natively punctuated and
/// capitalized, and the only engine here that reports per-token timings.
///
/// This is the *batch* TDT path (`AsrManager`), deliberately. The encoder takes
/// a fixed 240 000-sample (15 s) block whatever you feed it, so ANE cost is per
/// CALL, not per second of audio — which is why `WindowedTranscriber` sends one
/// utterance per call instead of overlapping fixed windows.
///
/// Decoder state is carried across calls through `ParakeetContext`, one per
/// channel, so a sentence split across two calls keeps its language-model
/// context. FluidAudio's own long-form path is stateless-per-chunk because it
/// decodes chunks in parallel and cuts them at arbitrary offsets; we decode
/// serially and cut at pauses, so carrying state is both safe and useful.
public final class ParakeetEngine: AsrEngine, @unchecked Sendable {
    /// Wire engine id (also persisted as `asr_model` in settings.json).
    public static let engineId = "parakeet-tdt-v3"
    /// Reported in hello_ack engine_versions (FluidAudio package revision).
    public static let version = "0.15.2"
    private static let modelVersion: AsrModelVersion = .v3
    private static let encoderPrecision: ParakeetEncoderPrecision = .int8

    public let id = ParakeetEngine.engineId
    /// nil ⇒ auto-detect (v3's default). A hint only narrows script filtering.
    private let language: Language?
    private let manager: AsrManager

    private struct PrepState {
        var prepared = false
        var preparing: Task<Void, Error>?
    }
    private let prepareLock = NSLock()
    private var prepState = PrepState()
    /// Serializes `transcribe` across both channels — see `TranscribeQueue`.
    private let queue = TranscribeQueue()

    private func withPrepState<R>(_ body: (inout PrepState) -> R) -> R {
        prepareLock.lock(); defer { prepareLock.unlock() }
        return body(&prepState)
    }

    public var isReady: Bool { withPrepState { $0.prepared } }

    /// - Parameter language: BCP-47-ish code, or "auto" (the default) to let v3
    ///   detect. An unrecognized code is treated as auto rather than failing.
    public init(language: String = "auto") {
        self.language = language == "auto" ? nil : Language(rawValue: language)
        // Windows are capped well under the 15 s encoder block, so the chunked
        // long-form path is never entered and its worker pool never allocated.
        self.manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
    }

    // MARK: - Model cache

    static func modelDirectory() -> URL? {
        ModelCache.modelsBaseDirectory()?
            .appendingPathComponent(Repo.parakeetV3.folderName)
    }

    /// Files that must all be present for the cache to be usable.
    static func requiredEntries() -> [String] {
        Array(ModelNames.ASR.requiredModelsV3(precision: encoderPrecision))
            + [ModelNames.ASR.vocabulary(for: Repo.parakeetV3)]
    }

    /// Directory-injectable core of `modelsCached`, so the completeness rules
    /// can be tested without a real 461 MB download in Application Support.
    static func modelsComplete(in dir: URL) -> Bool {
        ModelCache.complete(in: dir, entries: requiredEntries(), version: version)
    }

    /// True if the v3 CoreML models are completely present in the local cache —
    /// drives `models_ready` in hello_ack without touching the network.
    public static func modelsCached() -> Bool {
        guard let dir = modelDirectory() else { return false }
        return modelsComplete(in: dir)
    }

    // MARK: - Prepare

    /// Downloads (if needed), compiles and loads the models. Idempotent and
    /// coalesces concurrent callers into one underlying task.
    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let manager = self.manager
        let task: Task<Void, Error>? = withPrepState { state in
            if state.prepared { return nil }
            if let existing = state.preparing { return existing }
            let task = Task {
                // A cache that fails our completeness check may still satisfy
                // FluidAudio's own gate; clear its sentinel so the missing files
                // are actually refetched instead of loading and failing.
                if !ParakeetEngine.modelsCached() {
                    ModelCache.repairIncomplete(dir: ParakeetEngine.modelDirectory(),
                                                sentinels: ["config.json"],
                                                label: Repo.parakeetV3.folderName)
                }
                let models = try await AsrModels.downloadAndLoad(
                    version: ParakeetEngine.modelVersion,
                    encoderPrecision: ParakeetEngine.encoderPrecision,
                    progressHandler: { p in
                        let stage: String
                        switch p.phase {
                        case .listing, .downloading: stage = "downloading"
                        case .compiling: stage = "compiling"
                        }
                        progress(p.fractionCompleted, stage)
                    })
                try await manager.loadModels(models)
                // Only now — downloaded, compiled and loaded — is the cache
                // provably good; stamp it so later launches trust it cheaply.
                ModelCache.markReady(dir: ParakeetEngine.modelDirectory(),
                                     version: ParakeetEngine.version)
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

    // MARK: - Transcribe

    public func makeContext() -> AsrContext {
        ParakeetContext(decoderLayers: ParakeetEngine.modelVersion.decoderLayers)
    }

    /// Transcribes one utterance, carrying `context`'s decoder state through it.
    ///
    /// Both capture channels share this engine, so the decode runs on `queue`
    /// (the `AsrEngine` contract requires implementations to serialize
    /// concurrent callers themselves).
    public func transcribe(window: [Float], sampleRate: Int, context: AsrContext) async throws -> AsrResult {
        guard sampleRate == Int(Resampler.asrSampleRate) else {
            throw CaptureError.internalError("ParakeetEngine requires 16 kHz input, got \(sampleRate)")
        }
        guard let ctx = context as? ParakeetContext else {
            throw CaptureError.internalError("ParakeetEngine given a foreign AsrContext")
        }
        // FluidAudio rejects anything under 300 ms as invalid audio; that is
        // shorter than the transcriber's minimum utterance, but a capture gap
        // can still produce a stub. Nothing to say — don't spend an ANE call.
        guard window.count >= ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate) else {
            return AsrResult(text: "", confidence: -1)
        }
        let manager = self.manager
        let language = self.language
        let result = try await queue.run {
            var state = ctx.takeState()
            do {
                let r = try await manager.transcribe(window, decoderState: &state, language: language)
                ctx.putState(state)
                return r
            } catch {
                // Half-updated state would poison every later window.
                ctx.reset()
                throw error
            }
        }
        let timings: [AsrTokenTiming] = (result.tokenTimings ?? []).map {
            AsrTokenTiming(token: $0.token, startS: $0.startTime, endS: $0.endTime,
                           confidence: Double($0.confidence))
        }
        return AsrResult(text: result.text,
                         confidence: Double(result.confidence),
                         tokenTimings: timings)
    }
}

/// Per-channel TDT decoder state (predictor LSTM + last token + time jump).
public final class ParakeetContext: AsrContext, @unchecked Sendable {
    private let decoderLayers: Int
    private let lock = NSLock()
    private var state: TdtDecoderState

    init(decoderLayers: Int) {
        self.decoderLayers = decoderLayers
        self.state = TdtDecoderState.make(decoderLayers: decoderLayers)
    }

    func takeState() -> TdtDecoderState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func putState(_ newState: TdtDecoderState) {
        lock.lock(); defer { lock.unlock() }
        state = newState
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        state = TdtDecoderState.make(decoderLayers: decoderLayers)
    }
}
