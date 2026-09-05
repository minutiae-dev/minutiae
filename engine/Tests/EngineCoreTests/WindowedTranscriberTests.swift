import XCTest
@testable import EngineCore

final class FakeAsrEngine: AsrEngine, @unchecked Sendable {
    let id = "fake-engine"
    private let lock = NSLock()
    private var responses: [String]
    private var _ready: Bool
    private var _contextResets = 0
    private(set) var calls = 0
    /// Sample counts handed to the engine, in order.
    private(set) var windowSizes: [Int] = []
    /// Token timings returned with every response, when set.
    var timings: [AsrTokenTiming] = []

    init(responses: [String], ready: Bool = true) {
        self.responses = responses
        self._ready = ready
    }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return _ready }
    func setReady(_ v: Bool) { lock.lock(); _ready = v; lock.unlock() }
    var contextResets: Int { lock.lock(); defer { lock.unlock() }; return _contextResets }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        setReady(true)
    }

    func makeContext() -> AsrContext { CountingContext(engine: self) }

    func noteReset() { lock.lock(); _contextResets += 1; lock.unlock() }

    func transcribe(window: [Float], sampleRate: Int, context: AsrContext) async throws -> AsrResult {
        lock.lock(); defer { lock.unlock() }
        let text = responses.isEmpty ? "" : responses[min(calls, responses.count - 1)]
        calls += 1
        windowSizes.append(window.count)
        return AsrResult(text: text, confidence: 0.9, tokenTimings: timings)
    }
}

/// Records context resets so tests can assert the decoder is not asked to
/// continue a sentence across a silence or a capture gap.
final class CountingContext: AsrContext, @unchecked Sendable {
    private weak var engine: FakeAsrEngine?
    init(engine: FakeAsrEngine) { self.engine = engine }
    func reset() { engine?.noteReset() }
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

    /// Miniature scale: 1000 Hz "sample rate", 100 ms blocks. Every constant
    /// the segmenter uses is in seconds, so the real geometry applies:
    /// 0.7 s end-of-utterance silence, 10 s cap, 0.3 s guard.
    private func makeTranscriber(engine: FakeAsrEngine, collector: SegmentCollector,
                                 channel: Channel = .me,
                                 allocator: SegmentIndexAllocator = SegmentIndexAllocator()) -> WindowedTranscriber {
        WindowedTranscriber(channel: channel, engine: engine, indexAllocator: allocator,
                            sampleRate: 1000, blockSeconds: 0.1,
                            bufferCapacitySeconds: 30,
                            stopReadyTimeout: 0.2) { collector.append($0) }
    }

    private func loud(_ count: Int) -> [Float] {
        (0..<count).map { $0 % 2 == 0 ? 0.5 : -0.5 }
    }

    private func quiet(_ count: Int) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    // The hard product guarantee: silence produces ZERO segments and the ASR
    // is never invoked.
    func testSilenceGateProducesZeroSegments() async {
        let engine = FakeAsrEngine(responses: ["should never appear"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        t.feed(samples: quiet(5_000), firstSampleTime: 0)
        await t.finish()

        XCTAssertEqual(engine.calls, 0, "ASR must not run on silent audio")
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

    /// Long silence is discarded in place: the ring must not grow with it, or
    /// a quiet meeting would blow the buffer and drop the speech that follows.
    func testLongSilenceIsTrimmedNotBuffered() async {
        let engine = FakeAsrEngine(responses: ["after the pause"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        for i in 0..<20 {
            t.feed(samples: quiet(1_000), firstSampleTime: Double(i))
        }
        t.feed(samples: loud(1_000), firstSampleTime: 20)
        await t.finish()

        XCTAssertEqual(engine.calls, 1)
        // The utterance carries at most the 0.3 s guard of leading silence.
        XCTAssertLessThanOrEqual(engine.windowSizes[0], 1_400)
        XCTAssertEqual(collector.segments.count, 1)
        XCTAssertEqual(collector.segments[0].t0, 19.7, accuracy: 0.15)
    }

    /// One phrase, one ANE call — the whole point of utterance segmentation.
    func testOneUtteranceIsOneCall() async {
        let engine = FakeAsrEngine(responses: ["hello world how are you"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        t.feed(samples: loud(3_000), firstSampleTime: 0)
        await t.finish()

        XCTAssertEqual(engine.calls, 1, "3 s of continuous speech is one utterance, not four windows")
        let segs = collector.segments
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].idx, 0)
        XCTAssertEqual(segs[0].text, "hello world how are you")
        XCTAssertEqual(segs[0].t0, 0.0, accuracy: 0.01)
        XCTAssertEqual(segs[0].t1, 3.0, accuracy: 0.05)
        XCTAssertTrue(segs[0].isFinal)
        XCTAssertEqual(segs[0].engine, "fake-engine")
        XCTAssertEqual(segs[0].confidence, 0.9, accuracy: 1e-9)
    }

    /// A pause splits the stream; the second utterance is a separate call with
    /// its own timestamps, and no text de-dup is involved.
    func testPauseSplitsUtterances() async {
        let engine = FakeAsrEngine(responses: ["first phrase", "second phrase"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        t.feed(samples: loud(1_500), firstSampleTime: 0)          // 0.0 - 1.5 s
        t.feed(samples: quiet(1_200), firstSampleTime: 1.5)       // 1.2 s pause
        t.feed(samples: loud(1_500), firstSampleTime: 2.7)        // 2.7 - 4.2 s
        await t.finish()

        XCTAssertEqual(engine.calls, 2)
        let segs = collector.segments
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "first phrase")
        XCTAssertEqual(segs[0].t0, 0.0, accuracy: 0.01)
        // The cut keeps the 0.3 s guard on each side of the speech, so the
        // span is a little wider than the words. An engine that reports token
        // timings (Parakeet does) narrows it back down; this stub does not.
        XCTAssertEqual(segs[0].t1, 1.8, accuracy: 0.15)
        XCTAssertEqual(segs[1].text, "second phrase")
        XCTAssertEqual(segs[1].t0, 2.4, accuracy: 0.15)
        XCTAssertEqual(segs[1].t1, 4.2, accuracy: 0.2)
    }

    /// Repeated text is no longer trimmed — with no overlap there is nothing
    /// to de-dup, and a speaker really can say the same thing twice.
    func testRepeatedTextIsNotDeduped() async {
        let engine = FakeAsrEngine(responses: ["hello world", "hello world"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        t.feed(samples: loud(1_000), firstSampleTime: 0)
        t.feed(samples: quiet(1_000), firstSampleTime: 1.0)
        t.feed(samples: loud(1_000), firstSampleTime: 2.0)
        await t.finish()
        XCTAssertEqual(engine.calls, 2)
        XCTAssertEqual(collector.segments.map(\.text), ["hello world", "hello world"])
    }

    /// Casing and punctuation reach the transcript untouched — Parakeet
    /// produces them natively and they are most of what makes it readable.
    func testTextKeepsCasingAndPunctuation() async {
        let engine = FakeAsrEngine(responses: ["Hello, world. How are you?"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        t.feed(samples: loud(1_000), firstSampleTime: 0)
        await t.finish()
        XCTAssertEqual(collector.segments.first?.text, "Hello, world. How are you?")
    }

    /// A speaker who never pauses still gets text: the utterance is cut at the
    /// cap, and the cut lands in the quietest block available.
    func testForcedCutAtMaxWindow() async {
        let engine = FakeAsrEngine(responses: ["first half", "second half"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        // 8 s loud, a single quiet block at 8.0-8.1 s (too short to end the
        // utterance), then loud past the 10 s cap.
        t.feed(samples: loud(8_000), firstSampleTime: 0)
        t.feed(samples: quiet(100), firstSampleTime: 8.0)
        t.feed(samples: loud(4_000), firstSampleTime: 8.1)
        await t.finish()

        XCTAssertGreaterThanOrEqual(engine.calls, 2)
        let segs = collector.segments
        XCTAssertEqual(segs[0].text, "first half")
        // Cut at the centre of the quiet block, not at the raw 10 s cap.
        XCTAssertEqual(segs[0].t1, 8.05, accuracy: 0.2)
    }

    /// Token timings place the words inside the utterance; the outer bounds
    /// are only a fallback for engines that report none.
    func testTokenTimingsNarrowTheSegment() async {
        let engine = FakeAsrEngine(responses: ["hello"])
        engine.timings = [AsrTokenTiming(token: "hello", startS: 0.4, endS: 0.9, confidence: 0.8)]
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        t.feed(samples: loud(2_000), firstSampleTime: 5.0)
        await t.finish()
        let seg = try? XCTUnwrap(collector.segments.first)
        XCTAssertEqual(seg?.t0 ?? 0, 5.4, accuracy: 0.01)
        XCTAssertEqual(seg?.t1 ?? 0, 5.9, accuracy: 0.01)
    }

    /// Carrying decoder state across a pause lets a short utterance decode to
    /// just the punctuation closing the previous sentence. Seen live: a 0.08 s
    /// segment whose entire text was ".".
    func testPunctuationOnlyResultIsNotEmitted() async {
        let engine = FakeAsrEngine(responses: ["."])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        t.feed(samples: loud(1_000), firstSampleTime: 0)
        await t.finish()
        XCTAssertEqual(engine.calls, 1)
        XCTAssertTrue(collector.segments.isEmpty, "a segment of pure punctuation is noise")
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
        XCTAssertEqual(idxs, Array(0..<collector.segments.count),
                       "idx must be unique and monotonic across both channels")
    }

    func testFinalPartialUtteranceDrainedOnFinish() async {
        let engine = FakeAsrEngine(responses: ["tail words"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        // Still speaking when the session stops — no trailing pause to cut on.
        t.feed(samples: loud(600), firstSampleTime: 0)
        await t.finish()
        XCTAssertEqual(engine.calls, 1)
        XCTAssertEqual(collector.segments.count, 1)
        XCTAssertEqual(collector.segments[0].t1, 0.6, accuracy: 0.05)
    }

    // MARK: Model warm-up

    /// The race this replaces: windows used to be popped out of the ring and
    /// handed to an engine that threw `notInitialized`, so the opening seconds
    /// of a meeting were lost whenever the models were still loading.
    func testAudioIsHeldUntilEngineIsReady() async {
        let engine = FakeAsrEngine(responses: ["opening words"], ready: false)
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        t.feed(samples: loud(1_500), firstSampleTime: 0)
        t.feed(samples: quiet(1_000), firstSampleTime: 1.5)
        await t.finish()

        XCTAssertEqual(engine.calls, 0, "must not call an engine that is not ready")
        XCTAssertTrue(collector.segments.isEmpty)
        XCTAssertEqual(t.droppedWindows, 0, "held audio is not dropped audio")

        engine.setReady(true)
        t.engineBecameReady()
        await t.finish()

        XCTAssertEqual(engine.calls, 1)
        XCTAssertEqual(collector.segments.count, 1)
        // Timestamps are the ORIGINAL capture times, not the time it thawed.
        XCTAssertEqual(collector.segments[0].t0, 0.0, accuracy: 0.05)
        XCTAssertEqual(collector.segments[0].t1, 1.8, accuracy: 0.15)
    }

    /// Silence during warm-up still costs nothing and is not held.
    func testSilenceDuringWarmupIsStillDiscarded() async {
        let engine = FakeAsrEngine(responses: ["nope"], ready: false)
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)
        for i in 0..<10 { t.feed(samples: quiet(1_000), firstSampleTime: Double(i)) }
        engine.setReady(true)
        await t.finish()
        XCTAssertEqual(engine.calls, 0)
        XCTAssertTrue(collector.segments.isEmpty)
    }

    /// A warm-up longer than the ring overflows it. The audio is gone either
    /// way, but the timestamps of what survives must still be true — they used
    /// to slide earlier by the whole dropped duration.
    func testTimestampsSurviveRingOverflowDuringWarmup() async {
        let engine = FakeAsrEngine(responses: ["late words"], ready: false)
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        // 40 s of speech into a 30 s ring.
        for i in 0..<40 { t.feed(samples: loud(1_000), firstSampleTime: Double(i)) }
        XCTAssertGreaterThan(t.droppedWindows, 0)

        engine.setReady(true)
        t.feed(samples: quiet(1_000), firstSampleTime: 40)
        await t.finish()

        let segs = collector.segments
        XCTAssertFalse(segs.isEmpty)
        // The oldest surviving audio is ~30 s in, never 0 s.
        XCTAssertGreaterThan(segs[0].t0, 5.0,
                             "dropped samples must advance the time base, not shift every later segment early")
        XCTAssertLessThanOrEqual(segs.last!.t1, 41.0)
    }

    // MARK: Capture gaps

    /// The system tap stops delivering while the output device is idle. The
    /// stream is re-anchored so what comes back is timed where it really is.
    func testCaptureGapDoesNotShiftLaterTimestamps() async {
        let engine = FakeAsrEngine(responses: ["before", "after"])
        let collector = SegmentCollector()
        let t = makeTranscriber(engine: engine, collector: collector)

        t.feed(samples: loud(1_000), firstSampleTime: 0)
        // The source delivers nothing at all for 30 s, then resumes.
        t.feed(samples: loud(1_000), firstSampleTime: 31)
        await t.finish()

        let segs = collector.segments
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].t0, 0.0, accuracy: 0.05)
        XCTAssertEqual(segs[1].t0, 31.0, accuracy: 0.05,
                       "audio after a capture hole must not be timed as if the hole never happened")
        XCTAssertGreaterThan(engine.contextResets, 0,
                             "a hole ends the sentence — the decoder must not carry context across it")
    }

    // MARK: Segmentation planner (pure)

    private var params: WindowedTranscriber.Params {
        WindowedTranscriber.Params(guardBlocks: 3, endSilenceBlocks: 7, maxSamples: 10_000,
                                   cutSearchBlocks: 30, minSamples: 300, gateDbfs: -50)
    }

    private func levels(_ pattern: String) -> [Double] {
        pattern.map { $0 == "#" ? -10.0 : -90.0 }
    }

    func testPlanWaitsWhileSpeechContinues() {
        let p = WindowedTranscriber.plan(blockDbfs: levels("####"), blockSamples: 100,
                                         available: 400, limit: 400, drain: false, params: params)
        XCTAssertEqual(p, .wait)
    }

    func testPlanTrimsLeadingSilenceKeepingGuard() {
        let p = WindowedTranscriber.plan(blockDbfs: levels(".........."), blockSamples: 100,
                                         available: 1000, limit: 1000, drain: false, params: params)
        XCTAssertEqual(p, .trim(samples: 700), "keeps the 3-block guard")
    }

    func testPlanEmitsAfterEndSilence() {
        // 3 loud blocks then 7 silent ones ends the utterance; the cut keeps
        // the guard after the last speech.
        let p = WindowedTranscriber.plan(blockDbfs: levels("###........"), blockSamples: 100,
                                         available: 1100, limit: 1100, drain: false, params: params)
        XCTAssertEqual(p, .emit(samples: 600))
    }

    func testPlanForcesACutAtTheCap() {
        // 100 blocks of speech with a quiet one at index 80; the cap is 10 000
        // samples = 100 blocks, and the cut lands at the end of the quiet one
        // rather than at the raw cap.
        var l = levels(String(repeating: "#", count: 100))
        l[80] = -90
        let p = WindowedTranscriber.plan(blockDbfs: l, blockSamples: 100,
                                         available: 10_000, limit: 10_000, drain: false, params: params)
        XCTAssertEqual(p, .emit(samples: 8_100))
    }

    /// The search only looks back `cutSearchBlocks`; a quiet patch older than
    /// that is not a candidate, and the cut falls at the start of the window.
    func testPlanForcedCutIgnoresQuietOutsideTheSearchWindow() {
        var l = levels(String(repeating: "#", count: 100))
        l[60] = -90
        let p = WindowedTranscriber.plan(blockDbfs: l, blockSamples: 100,
                                         available: 10_000, limit: 10_000, drain: false, params: params)
        XCTAssertEqual(p, .emit(samples: 7_100))
    }

    func testPlanNeverSpansACaptureBoundary() {
        let p = WindowedTranscriber.plan(blockDbfs: levels("##########"), blockSamples: 100,
                                         available: 1000, limit: 400, drain: false, params: params)
        XCTAssertEqual(p, .emit(samples: 400))
    }

    func testPlanDrainsTheTailOnStop() {
        let p = WindowedTranscriber.plan(blockDbfs: levels("###"), blockSamples: 100,
                                         available: 350, limit: 350, drain: true, params: params)
        XCTAssertEqual(p, .emit(samples: 350))
    }

    func testPlanDrainDiscardsSilentTail() {
        let p = WindowedTranscriber.plan(blockDbfs: levels("..."), blockSamples: 100,
                                         available: 350, limit: 350, drain: true, params: params)
        XCTAssertEqual(p, .trim(samples: 350))
    }

    // MARK: Pure helper functions

    func testRmsDbfs() {
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([]), -120)
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([0, 0, 0]), -120)
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([1, -1, 1, -1]), 0, accuracy: 1e-9)
        XCTAssertEqual(WindowedTranscriber.rmsDbfs([0.5, -0.5]), -6.02, accuracy: 0.01)
    }
}
