import XCTest
@testable import EngineCore

final class FakeAsrEngine: AsrEngine, @unchecked Sendable {
    let id = "fake-engine"
    private let lock = NSLock()
    private var responses: [String]
    private(set) var calls = 0

    init(responses: [String]) {
        self.responses = responses
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}

    func transcribe(window: [Float], sampleRate: Int) async throws -> AsrResult {
        lock.lock(); defer { lock.unlock() }
        let text = responses.isEmpty ? "" : responses[min(calls, responses.count - 1)]
        calls += 1
        return AsrResult(text: text, confidence: 0.9)
    }
}

final class SegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Segment] = []
    var segments: [Segment] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ s: Segment) {
        lock.lock(); defer { lock.unlock() }
        storage.append(s)
    }
}

final class WindowedTranscriberTests: XCTestCase {

    /// Miniature scale: 1000 Hz "sample rate", 1 s window, 0.8 s hop.
    private func makeTranscriber(engine: FakeAsrEngine, collector: SegmentCollector,
                                 channel: Channel = .me,
                                 allocator: SegmentIndexAllocator = SegmentIndexAllocator()) -> WindowedTranscriber {
        WindowedTranscriber(channel: channel, engine: engine, indexAllocator: allocator,
                            sampleRate: 1000, windowSeconds: 1.0, hopSeconds: 0.8,
                            bufferCapacitySeconds: 30) { collector.append($0) }
    }

    private func loud(_ count: Int) -> [Float] {
        (0..<count).map { $0 % 2 == 0 ? 0.5 : -0.5 }
    }

    // The hard product guarantee: silence produces ZERO segments and the ASR
    // is never invoked.
    func testSilenceGateProducesZeroSegments() async {
        let engine = FakeAsrEngine(responses: ["should never appear"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        t.feed(samples: [Float](repeating: 0, count: 5_000), firstSampleTime: 0)
        await t.finish()

        XCTAssertEqual(engine.calls, 0, "ASR must not run on silent windows")
        XCTAssertTrue(collector.segments.isEmpty, "silence must produce zero segments")
    }

    func testNearSilenceBelowGateIsSkipped() async {
        // Amplitude 1e-4 ≈ −80 dBFS, well under the −50 dBFS gate.
        let engine = FakeAsrEngine(responses: ["nope"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        t.feed(samples: [Float](repeating: 1e-4, count: 3_000), firstSampleTime: 0)
        await t.finish()
        XCTAssertEqual(engine.calls, 0)
        XCTAssertTrue(collector.segments.isEmpty)
    }

    func testLoudAudioEmitsSegmentsWithTimes() async {
        let engine = FakeAsrEngine(responses: ["hello world how are you",
                                               "are you doing well today"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        // 1800 samples → window 1 at [0, 1000), window 2 at [800, 1800).
        t.feed(samples: loud(1800), firstSampleTime: 0)
        await t.finish()

        XCTAssertEqual(engine.calls, 2)
        let segs = collector.segments
        XCTAssertEqual(segs.count, 2)

        XCTAssertEqual(segs[0].idx, 0)
        XCTAssertEqual(segs[0].text, "hello world how are you")
        XCTAssertEqual(segs[0].t0, 0.0, accuracy: 0.01)
        XCTAssertEqual(segs[0].t1, 1.0, accuracy: 0.01)
        XCTAssertTrue(segs[0].isFinal)
        XCTAssertEqual(segs[0].engine, "fake-engine")
        XCTAssertEqual(segs[0].confidence, 0.9, accuracy: 1e-9)

        // Overlap de-dup: leading "are you" matched the previous tail.
        XCTAssertEqual(segs[1].idx, 1)
        XCTAssertEqual(segs[1].text, "doing well today")
        XCTAssertEqual(segs[1].t0, 0.8, accuracy: 0.01)
        XCTAssertEqual(segs[1].t1, 1.8, accuracy: 0.01)
    }

    func testIdenticalOverlapWindowFullyDeduped() async {
        let engine = FakeAsrEngine(responses: ["hello world", "hello world"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        t.feed(samples: loud(1800), firstSampleTime: 0)
        await t.finish()
        XCTAssertEqual(engine.calls, 2)
        XCTAssertEqual(collector.segments.count, 1, "fully duplicated window must not re-emit")
        XCTAssertEqual(collector.segments[0].text, "hello world")
    }

    func testIdxMonotonicAcrossChannels() async {
        let allocator = SegmentIndexAllocator()
        let engine = FakeAsrEngine(responses: ["alpha beta", "gamma delta", "epsilon zeta", "eta theta"])
        let collector = SegmentCollector()
        let me = makeTranscriber(engine: engine, collector: collector, channel: .me, allocator: allocator)
        let them = makeTranscriber(engine: engine, collector: collector, channel: .them, allocator: allocator)

        me.feed(samples: loud(1000), firstSampleTime: 0)
        await me.finish()
        them.feed(samples: loud(1000), firstSampleTime: 0)
        await them.finish()

        let idxs = collector.segments.map(\.idx).sorted()
        XCTAssertEqual(idxs, Array(0..<collector.segments.count), "idx must be unique and monotonic across both channels")
    }

    func testFinalPartialWindowDrainedOnFinish() async {
        let engine = FakeAsrEngine(responses: ["tail words"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        // 600 samples: under a full window but over the 0.5 s drain minimum.
        t.feed(samples: loud(600), firstSampleTime: 0)
        await t.finish()
        XCTAssertEqual(engine.calls, 1)
        XCTAssertEqual(collector.segments.count, 1)
        XCTAssertEqual(collector.segments[0].t1, 0.6, accuracy: 0.01)
    }

    // MARK: Pure helper functions

    func testRmsDbfs() {
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([]), -120)
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([0, 0, 0]), -120)
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([1, -1, 1, -1]), 0, accuracy: 1e-9)
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([0.5, -0.5]), -6.02, accuracy: 0.01)
    }

    func testTrimOverlap() {
        XCTAssertEqual(WindowedTranscriber.trimOverlap(tokens: ["c", "d", "e"], previousTail: ["a", "b", "c", "d"]),
                       ["e"])
        XCTAssertEqual(WindowedTranscriber.trimOverlap(tokens: ["x", "y"], previousTail: ["a", "b"]),
                       ["x", "y"])
        XCTAssertEqual(WindowedTranscriber.trimOverlap(tokens: ["a", "b"], previousTail: ["a", "b"]),
                       [])
        XCTAssertEqual(WindowedTranscriber.trimOverlap(tokens: ["a"], previousTail: []),
                       ["a"])
    }

    func testNormalizedTokens() {
        XCTAssertEqual(WindowedTranscriber.normalizedTokens("  Hello   World\n"), ["hello", "world"])
        XCTAssertEqual(WindowedTranscriber.normalizedTokens(""), [])
    }
}
