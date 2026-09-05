import AVFoundation
import XCTest
@testable import EngineCore

/// The shipped ASR path against the REAL models: batch Parakeet TDT v3 driven
/// by the utterance segmenter.
///
/// Opt-in — it downloads/loads CoreML models and runs the ANE:
///   say -o /tmp/speech.aiff "…"
///   MINUTIAE_E2E=1 MINUTIAE_E2E_SPEECH=/tmp/speech.aiff \
///     swift test --package-path engine --filter ParakeetEndToEndTests
final class ParakeetEndToEndTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["MINUTIAE_E2E"] == "1" }

    private func loadSpeech16k() throws -> [Float] {
        let path = ProcessInfo.processInfo.environment["MINUTIAE_E2E_SPEECH"] ?? ""
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: Resampler.asrSampleRate,
                                channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: file.processingFormat, to: out)!
        var result: [Float] = []
        var done = false
        while !done {
            let buf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: 16_000)!
            var err: NSError?
            let status = conv.convert(to: buf, error: &err) { _, s in
                let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
                do { try file.read(into: inBuf, frameCount: 16_384) } catch {
                    s.pointee = .endOfStream; return nil
                }
                if inBuf.frameLength == 0 { s.pointee = .endOfStream; return nil }
                s.pointee = .haveData
                return inBuf
            }
            if let d = buf.floatChannelData, buf.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength)))
            }
            if status == .endOfStream || status == .error { done = true }
        }
        return result
    }

    private func transcribe(_ samples: [Float], engine: AsrEngine,
                            feedSeconds: Double = 0.1) async -> [Segment] {
        let collector = SegmentCollector()
        let t = WindowedTranscriber(channel: .them, engine: engine,
                                    indexAllocator: SegmentIndexAllocator()) { collector.append($0) }
        let chunk = Int(feedSeconds * Resampler.asrSampleRate)
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            t.feed(samples: Array(samples[i..<end]),
                   firstSampleTime: Double(i) / Resampler.asrSampleRate)
            i = end
        }
        await t.finish()
        return collector.segments
    }

    /// Punctuation and capitalization are the readability win Parakeet brings
    /// over the streaming path, and the one thing worth proving against the
    /// real model rather than trusting the model card for.
    func testTranscriptIsPunctuatedAndCapitalized() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_E2E=1 to run")
        let engine = ParakeetEngine(language: "auto")
        try await engine.prepare { _, _ in }

        let speech = try loadSpeech16k()
        XCTAssertGreaterThan(speech.count, 16_000, "need at least a second of speech")
        let segments = await transcribe(speech, engine: engine)

        XCTAssertFalse(segments.isEmpty, "the real model must produce a transcript")
        let text = segments.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains(where: { ".?!,".contains($0) }),
                      "expected punctuation in: \(text)")
        XCTAssertTrue(text.contains(where: { $0.isUppercase }),
                      "expected capitalization in: \(text)")
        // Every segment must sit inside the audio it came from.
        let duration = Double(speech.count) / Resampler.asrSampleRate
        for seg in segments {
            XCTAssertGreaterThanOrEqual(seg.t0, -0.01)
            XCTAssertLessThanOrEqual(seg.t1, duration + 0.5)
            XCTAssertLessThanOrEqual(seg.t0, seg.t1)
        }
    }

    /// A speaker who never pauses is cut at the cap. The seam is the risk: a
    /// word split across two calls could be lost or doubled. Repeat the same
    /// speech until it is comfortably longer than the cap and check the words
    /// survive the forced cuts.
    func testForcedCutsDoNotLoseWords() async throws {
        try XCTSkipUnless(enabled, "set MINUTIAE_E2E=1 to run")
        let engine = ParakeetEngine(language: "auto")
        try await engine.prepare { _, _ in }

        let clip = try loadSpeech16k()
        // Back-to-back copies with no gap, past the 10 s cap.
        var continuous: [Float] = []
        while Double(continuous.count) / Resampler.asrSampleRate < 25 {
            continuous.append(contentsOf: clip)
        }

        let single = await transcribe(clip, engine: engine)
        let repeated = await transcribe(continuous, engine: engine)

        let words = { (segs: [Segment]) in
            segs.map(\.text).joined(separator: " ")
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let once = words(single)
        let many = words(repeated)
        XCTAssertFalse(once.isEmpty)

        let copies = Int((Double(continuous.count) / Double(clip.count)).rounded(.down))
        // Allow one word of slop per seam rather than demanding an exact
        // multiple: the point is that a forced cut does not swallow a clause.
        let expected = once.count * copies
        XCTAssertGreaterThan(many.count, expected - 2 * copies,
                             "forced cuts lost words: \(many.count) vs ~\(expected)")
    }
}
