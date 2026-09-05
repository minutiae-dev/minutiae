import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA Nemotron-3.5 streaming 0.6B on the Apple Neural Engine via FluidAudio
/// (pinned exact in Package.swift — 0.x API churn). Two variants:
///
/// - `.multilingual` — `Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`,
///   auto-detecting across 40+ locales. The shipped default.
/// - `.english` — `nemotron-speech-streaming-en-0.6b-coreml`, vocab-pruned and
///   faster; selectable from the hidden model picker.
///
/// FluidAudio's Nemotron managers are streaming actors, but Minutiae transcribes
/// fixed windows (see `WindowedTranscriber`). We honor the existing
/// stateless-per-window `AsrEngine` contract by resetting the manager, feeding
/// the whole window, and flushing with `finish()` — overlap de-dup and the RMS
/// silence gate stay upstream, unchanged.
public final class NemotronEngine: AsrEngine, @unchecked Sendable {
    public enum Variant: Sendable {
        case multilingual
        case english
    }

    /// Wire engine ids (also persisted as `asr_model` in settings.json).
    public static let multilingualId = "nemotron-streaming-ml"
    public static let englishId = "nemotron-streaming-en"
    /// Reported in hello_ack engine_versions (FluidAudio package revision).
    public static let version = "0.15.2"
    /// Chunk tier for both variants — 2240 ms is FluidAudio's recommended
    /// (highest-throughput, WER-neutral) streaming tier.
    private static let chunkMs = 2240

    public let id: String
    private let variant: Variant
    // Exactly one of these is non-nil, selected by `variant`.
    private let multilingual: StreamingNemotronMultilingualAsrManager?
    private let english: StreamingNemotronAsrManager?

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

    public init(variant: Variant) {
        self.variant = variant
        switch variant {
        case .multilingual:
            self.id = NemotronEngine.multilingualId
            self.multilingual = StreamingNemotronMultilingualAsrManager()
            self.english = nil
        case .english:
            self.id = NemotronEngine.englishId
            self.multilingual = nil
            self.english = StreamingNemotronAsrManager(requestedChunkSize: .ms2240)
        }
    }

    /// Maps a wire engine id to a variant, or nil if it isn't one of ours.
    public static func variant(forId id: String) -> Variant? {
        switch id {
        case multilingualId: return .multilingual
        case englishId: return .english
        default: return nil
        }
    }

    /// Mirrors FluidAudio's on-disk cache layout per variant. Multilingual nests
    /// a language directory (`multilingual/2240ms`); the English repo folder name
    /// already carries its chunk tier.
    static func modelDirectory(for variant: Variant) -> URL? {
        guard let base = ModelCache.modelsBaseDirectory() else { return nil }
        switch variant {
        case .multilingual:
            let langDir = StreamingNemotronMultilingualAsrManager.languageDirectory(for: "auto")
            return base
                .appendingPathComponent(Repo.nemotronMultilingual.folderName)
                .appendingPathComponent(langDir)
                .appendingPathComponent("\(chunkMs)ms")
        case .english:
            return base.appendingPathComponent(Repo.nemotronStreaming2240.folderName)
        }
    }

    /// Files that must all be present for a variant's cache to be usable.
    /// Multilingual's decode path is checked separately (it accepts either the
    /// fused `decoder_joint` or the bare `decoder` + `joint` pair).
    private static func requiredEntries(for variant: Variant) -> [String] {
        switch variant {
        case .multilingual:
            return [
                ModelNames.NemotronMultilingualStreaming.metadata,
                ModelNames.NemotronMultilingualStreaming.tokenizer,
                ModelNames.NemotronMultilingualStreaming.preprocessorFile,
                ModelNames.NemotronMultilingualStreaming.encoderFile,
            ]
        case .english:
            return Array(ModelNames.NemotronStreaming.requiredModels)
        }
    }

    /// True if `variant`'s CoreML models are completely present in the local
    /// cache — drives `models_ready` in hello_ack without touching the network.
    ///
    /// This checks every required artifact, not just `metadata.json`. FluidAudio
    /// downloads files individually with no completion sentinel and writes
    /// `metadata.json` near the end, so an interrupted first download leaves a
    /// populated directory that a single-file probe happily calls "ready" (or,
    /// in the reverse order, calls "missing" forever and re-downloads on every
    /// launch).
    public static func modelsCached(variant: Variant) -> Bool {
        guard let dir = modelDirectory(for: variant) else { return false }
        return modelsComplete(in: dir, variant: variant)
    }

    /// Directory-injectable core of `modelsCached`, so the completeness rules
    /// can be tested without a real 1.5 GB download in Application Support.
    static func modelsComplete(in dir: URL, variant: Variant) -> Bool {
        for entry in requiredEntries(for: variant) where !ModelCache.entryComplete(dir, entry) {
            return false
        }
        if case .multilingual = variant {
            let fused = ModelCache.entryComplete(dir, "decoder_joint.mlmodelc")
            let bare = ModelCache.entryComplete(dir, ModelNames.NemotronMultilingualStreaming.decoderFile)
                && ModelCache.entryComplete(dir, ModelNames.NemotronMultilingualStreaming.jointFile)
            guard fused || bare else { return false }
        }
        return ModelCache.markerMatches(in: dir, version: version)
    }

    /// Back-compat shorthand for the shipped default variant.
    public static func multilingualModelsCached() -> Bool {
        modelsCached(variant: .multilingual)
    }

    /// Downloads (if needed), compiles and loads the models. Idempotent and
    /// coalesces concurrent callers into one underlying task.
    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let task: Task<Void, Error>? = withPrepState { state in
            if state.prepared { return nil }
            if let existing = state.preparing { return existing }
            let variant = self.variant
            let multilingual = self.multilingual
            let english = self.english
            let task = Task {
                let handler: DownloadUtils.ProgressHandler = { p in
                    let stage: String
                    switch p.phase {
                    case .listing, .downloading: stage = "downloading"
                    case .compiling: stage = "compiling"
                    }
                    progress(p.fractionCompleted, stage)
                }
                // A cache that fails our completeness check may still satisfy
                // FluidAudio's metadata-only gate; clear it so the missing files
                // are actually refetched instead of loading and failing.
                if !NemotronEngine.modelsCached(variant: variant) {
                    // `downloadVariant` decides "already cached" purely on
                    // metadata.json, so a directory that has metadata but lost
                    // (or never finished) a model file would skip the download
                    // and then fail to load — unfixable without clearing it.
                    ModelCache.repairIncomplete(
                        dir: NemotronEngine.modelDirectory(for: variant),
                        sentinels: [ModelNames.NemotronMultilingualStreaming.metadata],
                        label: NemotronEngine.modelDirectory(for: variant)?.lastPathComponent ?? "?")
                }
                switch variant {
                case .multilingual:
                    guard let multilingual else { return }
                    let shared = try await StreamingNemotronMultilingualAsrManager
                        .downloadAndPreloadShared(languageCode: "auto",
                                                  chunkMs: NemotronEngine.chunkMs,
                                                  progressHandler: handler)
                    try await multilingual.loadFromShared(shared)
                    await multilingual.setLanguage("auto")
                case .english:
                    guard let english else { return }
                    try await english.loadModels(to: nil, configuration: nil, progressHandler: handler)
                }
                // Only now — downloaded, compiled and loaded — is the cache
                // provably good; stamp it so later launches trust it cheaply.
                ModelCache.markReady(dir: NemotronEngine.modelDirectory(for: variant),
                                     version: NemotronEngine.version)
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

    /// Stateless per-window transcription — the streaming manager is reset
    /// before every window, so `context` is unused. Nemotron's String API
    /// reports no per-token timing/confidence, so `tokenTimings` is empty and
    /// `confidence` is -1; `WindowedTranscriber` then derives segment t0/t1
    /// from the utterance's own bounds.
    ///
    /// Both capture channels share this engine, so the reset→process→finish
    /// triple runs on `queue` to keep it atomic (the `AsrEngine` contract
    /// requires implementations to serialize concurrent callers themselves).
    public func makeContext() -> AsrContext { StatelessAsrContext() }

    public func transcribe(window: [Float], sampleRate: Int,
                           context: AsrContext) async throws -> AsrResult {
        guard sampleRate == Int(Resampler.asrSampleRate) else {
            throw CaptureError.internalError("NemotronEngine requires 16 kHz input, got \(sampleRate)")
        }
        let variant = self.variant
        let multilingual = self.multilingual
        let english = self.english
        let text = try await queue.run {
            switch variant {
            case .multilingual:
                guard let m = multilingual else {
                    throw CaptureError.internalError("Nemotron multilingual engine not initialized")
                }
                await m.reset()
                _ = try await m.process(samples: window)
                return try await m.finish()
            case .english:
                guard let e = english else {
                    throw CaptureError.internalError("Nemotron english engine not initialized")
                }
                await e.reset()
                let buffer = try NemotronEngine.makeBuffer(from: window, sampleRate: sampleRate)
                _ = try await e.process(audioBuffer: buffer)
                return try await e.finish()
            }
        }
        return AsrResult(text: text, confidence: -1, tokenTimings: [])
    }

    /// The English manager only accepts `AVAudioPCMBuffer`; wrap the already
    /// 16 kHz mono Float32 window (its internal converter is then a no-op).
    private static func makeBuffer(from samples: [Float], sampleRate: Int) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw CaptureError.internalError("failed to allocate AVAudioPCMBuffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData, !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}
