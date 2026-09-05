import Foundation

/// Completeness checking for FluidAudio's on-disk CoreML cache.
///
/// FluidAudio downloads files individually with no completion sentinel and
/// writes its metadata near the end, so a single-file probe misreads an
/// interrupted download: in one direction it declares a broken cache ready and
/// the load fails at runtime, in the other it calls a good cache missing and
/// re-downloads ~1.5 GB on every launch.
///
/// Every engine therefore checks each required artifact, and stamps a marker
/// only once the models have actually downloaded, compiled AND loaded.
public enum ModelCache {
    /// Written into a model directory once `prepare()` has fully succeeded.
    /// Contents are the FluidAudio revision, so a deliberate `.exact` bump in
    /// Package.swift invalidates a cache built by the old version.
    public static let readyMarkerName = ".minutiae-models-ready"

    /// `~/Library/Application Support/FluidAudio/Models`.
    public static func modelsBaseDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// A `.mlmodelc` is a directory, and CoreML only accepts it once
    /// `coremldata.bin` is inside — which is exactly what a half-written one
    /// lacks, so a plain `fileExists` on the directory would pass a broken model.
    /// Everything else must exist and be non-empty.
    public static func entryComplete(_ dir: URL, _ relativePath: String) -> Bool {
        let url = dir.appendingPathComponent(relativePath)
        let fm = FileManager.default
        if relativePath.hasSuffix(".mlmodelc") {
            return fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
        }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 0
    }

    /// True when every entry is present and no marker from a different
    /// FluidAudio revision is in the way.
    public static func complete(in dir: URL, entries: [String], version: String) -> Bool {
        for entry in entries where !entryComplete(dir, entry) {
            return false
        }
        return markerMatches(in: dir, version: version)
    }

    /// A marker left by a different FluidAudio revision means these assets
    /// predate a deliberate version bump — re-prepare rather than load them.
    /// No marker at all is fine: a cache from before markers existed, or one
    /// whose files are all provably present.
    public static func markerMatches(in dir: URL, version: String) -> Bool {
        let marker = dir.appendingPathComponent(readyMarkerName)
        guard let stamped = try? String(contentsOf: marker, encoding: .utf8) else { return true }
        return stamped.trimmingCharacters(in: .whitespacesAndNewlines) == version
    }

    public static func markReady(dir: URL?, version: String) {
        guard let dir, FileManager.default.fileExists(atPath: dir.path) else { return }
        try? Data(version.utf8).write(to: dir.appendingPathComponent(readyMarkerName), options: .atomic)
    }

    /// Reopens FluidAudio's own cache gate for an incomplete download by
    /// removing the metadata file it uses as its "already cached" sentinel.
    /// Its downloader skips files already on disk, so only the missing ones
    /// come down again.
    public static func repairIncomplete(dir: URL?, sentinels: [String], label: String) {
        guard let dir, FileManager.default.fileExists(atPath: dir.path) else { return }
        log("ASR model cache at \(label) is incomplete — refetching missing files")
        for name in sentinels + [readyMarkerName] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
