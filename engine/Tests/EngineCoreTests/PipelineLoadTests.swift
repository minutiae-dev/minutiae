import AVFoundation
import XCTest
@testable import EngineCore

/// Resource benchmark for the capture pipeline, minus the ANE.
///
/// Runs a synthetic session (real writers, resamplers, echo analyzer, delay
/// line and windowed transcribers; stub ASR) far faster than realtime and
/// reports CPU seconds per session-minute, memory growth and bytes written.
/// Opt-in — it is a measurement, not a pass/fail check:
///
///   MINUTIAE_BENCH=1 MINUTIAE_BENCH_MINUTES=10 \
///     swift test -c release --package-path engine --filter PipelineLoadTests
final class PipelineLoadTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["MINUTIAE_BENCH"] == "1" }
    private var minutes: Double {
        Double(ProcessInfo.processInfo.environment["MINUTIAE_BENCH_MINUTES"] ?? "") ?? 5
    }

    func testCapturePipelineResourceProfile() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_BENCH=1 to run")
        try await bench(label: "mixed (20 s speech / 40 s silence)", speak: 20, silent: 40)
    }

    func testAllSpeechResourceProfile() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_BENCH=1 to run")
        try await bench(label: "continuous speech", speak: 1, silent: 0)
    }

    func testAllSilenceResourceProfile() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_BENCH=1 to run")
        try await bench(label: "continuous silence", speak: 0, silent: 1)
    }

    private func bench(label: String, speak: Double, silent: Double) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = SyntheticSession.Config()
        config.speakSeconds = speak
        config.silentSeconds = silent
        let asr = CountingAsrEngine()
        let session = try SyntheticSession(dir: dir, config: config, engine: asr)

        let seconds = minutes * 60
        let start = ProcMetrics.sample()
        session.run(seconds: seconds)
        let peakPartBytes = session.bytesOnDisk()
        let beforeFinalize = ProcMetrics.sample()
        let finalizeStart = CFAbsoluteTimeGetCurrent()
        let files = await session.finish()
        let finalizeSeconds = CFAbsoluteTimeGetCurrent() - finalizeStart
        let end = ProcMetrics.sample()
        let d = end.delta(since: start)
        // Split the total by PHASE, not by component: the Opus encoder runs on
        // a background queue during the session, and getrusage counts every
        // thread, so "during session" includes it. What this isolates is how
        // much work stop still has to do — which used to be the whole
        // transcode and is now just closing two files.
        let duringSession = beforeFinalize.cpuSeconds - start.cpuSeconds
        let atStop = d.cpu - duringSession

        let finalBytes = session.bytesOnDisk()
        func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
        func perHour(_ b: Int64) -> String {
            String(format: "%.2f GB/h", Double(b) / 1_073_741_824 / (seconds / 3600))
        }

        print("""

        -- BENCH: \(label) -- \(Int(seconds)) s of session audio --
          wall clock            \(String(format: "%.2f s", d.wall)) (\(String(format: "%.0fx", seconds / d.wall)) realtime)
          CPU total             \(String(format: "%.2f s", d.cpu))  -> \(String(format: "%.2f%%", 100 * d.cpu / seconds)) of one core at realtime
            during session      \(String(format: "%.2f s", duringSession))  -> \(String(format: "%.2f%%", 100 * duringSession / seconds))  (capture + background encode)
            at stop             \(String(format: "%.2f s", atStop))  -> \(String(format: "%.1f s", atStop * 3600 / seconds)) for a 1 h session
          footprint delta       \(mb(d.footprintDelta))
          stop -> finalized     \(String(format: "%.2f s", finalizeSeconds))  (\(String(format: "%.1f s", finalizeSeconds * 3600 / seconds)) for a 1 h session)
          peak in-session disk  \(mb(peakPartBytes))  (\(perHour(peakPartBytes)))
          final on disk         \(mb(finalBytes))  (\(perHour(finalBytes)))
          ANE calls             \(asr.calls)  (\(String(format: "%.0f", Double(asr.calls) * 3600 / seconds))/h) — the unit that costs, since the encoder block is fixed
          ASR audio             \(String(format: "%.0f s", Double(asr.samplesSeen) / 16_000))  (\(String(format: "%.0f%%", 100 * Double(asr.samplesSeen) / 16_000 / (seconds * 2))) of the 2-channel session)
          segments emitted      \(session.collected.segments.count)
          files                 \(files.map { "\($0.channel.rawValue):\($0.codec)/\($0.container)" }.joined(separator: " "))
        --------------------------------------------------------------

        """)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutiae-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
