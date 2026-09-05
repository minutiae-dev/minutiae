import Foundation

/// The set of ASR engines this build can run, and the mapping from the wire
/// `engine` id to a constructor.
///
/// The wire ids are also what the core persists as `asr_model` in settings.json
/// and writes into session.json, so they are a compatibility surface: add ids,
/// never rename them.
public enum AsrEngineRegistry {
    /// The shipped default: batch Parakeet TDT v3, multilingual and punctuated.
    public static let defaultId = ParakeetEngine.engineId

    /// Reported in hello_ack so the core knows what this build understands.
    public static var engineVersions: [String: String] {
        [
            ParakeetEngine.engineId: ParakeetEngine.version,
            NemotronEngine.multilingualId: NemotronEngine.version,
            NemotronEngine.englishId: NemotronEngine.version,
        ]
    }

    public static func isKnown(_ id: String) -> Bool {
        engineVersions[id] != nil
    }

    /// True when `id`'s models are completely present in the local cache.
    /// Unknown ids report false rather than answering for the default — a
    /// cached default masking a missing selected model would defer its
    /// download to the first start_session, which is the stall we removed.
    public static func modelsCached(id: String) -> Bool {
        if id == ParakeetEngine.engineId { return ParakeetEngine.modelsCached() }
        guard let variant = NemotronEngine.variant(forId: id) else { return false }
        return NemotronEngine.modelsCached(variant: variant)
    }

    /// Builds the engine for `id`. Unknown ids fall back to the default
    /// (start_session validates ids up front; hello/prepare default sensibly).
    public static func make(id: String, language: String) -> AsrEngine {
        if let variant = NemotronEngine.variant(forId: id) {
            return NemotronEngine(variant: variant)
        }
        return ParakeetEngine(language: language)
    }
}
