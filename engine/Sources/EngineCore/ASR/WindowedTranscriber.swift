import Accelerate
import Foundation

/// Allocates segment `idx` values monotonically across BOTH channels
/// (protocol: idx is unique per session across the channel-agnostic stream).
public final class SegmentIndexAllocator: @unchecked Sendable {
    private var next = 0
    private let lock = NSLock()
    public init() {}
    public func allocate() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = next
        next += 1
        return v
    }
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return next
    }
}

/// Per-channel transcription over a ring buffer of 16 kHz mono samples,
/// segmented into UTTERANCES rather than fixed windows.
///
/// Why utterances: Parakeet's CoreML encoder takes a fixed 15 s block whatever
/// you hand it, so one ANE call costs the same for 2 s of audio as for 10 s.
/// The old geometry (5 s window, 4 s hop) therefore paid for 25 % more audio
/// than the session contained and still needed a text de-dup pass to hide the
/// overlap. Cutting where the speaker pauses removes both: no overlap, no
/// de-dup, fewer calls, and each call sees a whole phrase rather than a slice
/// through the middle of one.
///
/// The segmenter walks the ring in 100 ms blocks and:
///  - trims leading silence in place, keeping `leadGuardSeconds` so a word
///    onset can never be clipped;
///  - opens an utterance on the first block above `silenceGateDbfs`;
///  - closes it after `endSilenceSeconds` of trailing quiet, or at
///    `maxWindowSeconds`, whichever comes first.
///
/// A forced cut at the cap lands at the CENTRE of the quietest block in the
/// last `cutSearchSeconds`, so a boundary a speaker never gave us is at least
/// placed where the audio is weakest. Decoder state (`AsrContext`) is carried
/// across cuts, so a sentence split by a forced cut keeps its language-model
/// context; a long silence or a capture discontinuity resets it, because
/// whatever comes next is not a continuation.
///
/// Hard product guarantees preserved from the windowed design:
///  - an RMS gate runs IN PLACE on the ring, so silence costs one vDSP pass
///    and a pointer bump — never a copy, never an ANE call, never a segment;
///  - audio buffered while the model is still loading is HELD in the ring and
///    transcribed once the engine reports ready, never dropped.
///
/// Every deduped utterance is emitted as `final: true` immediately. The
/// protocol allows non-final re-emission but does not require it.
public final class WindowedTranscriber: @unchecked Sendable {
    /// Envelope resolution for segmentation decisions.
    public static let blockSeconds = 0.1
    /// Tunable. dBFS; blocks quieter than this are silence.
    public static let silenceGateDbfs: Double = -50.0
    /// Trailing quiet that ends an utterance. Long enough not to cut on the
    /// gap between words, short enough that text lands about a second after
    /// the speaker stops.
    public static let endSilenceSeconds = 0.7
    /// Cap for a speaker who never pauses: the worst-case latency before any
    /// text appears, and the point at which a cut is forced.
    public static let maxWindowSeconds = 10.0
    /// How far back a forced cut looks for the quietest block.
    public static let cutSearchSeconds = 3.0
    /// Kept before the first loud block, and after the last one.
    public static let leadGuardSeconds = 0.3
    /// Shorter than this is not worth an ANE call (and FluidAudio rejects
    /// anything under 300 ms outright).
    public static let minUtteranceSeconds = 0.3
    /// Silence longer than this ends the linguistic context: what comes after
    /// it does not continue the sentence before it.
    public static let contextResetSilenceSeconds = 5.0
    /// A capture source that stops delivering for longer than this leaves a
    /// hole; the stream is re-anchored so later timestamps stay true.
    public static let discontinuitySeconds = 0.5
    /// Longest wait at session stop for models that are still loading, well
    /// inside the core's stop timeout. A first-run download is not waited for.
    public static let stopReadyTimeoutSeconds = 20.0

    /// Leading/trailing silence inside an utterance is bounded by the guard, so
    /// the extra trim is defensive only. Set MINUTIAE_ASR_TRIM=0 to disable.
    public static let trimGuardSeconds = 0.5
    public static var trimGateDbfs: Double { silenceGateDbfs - 10 }
    static let trimEnabled = ProcessInfo.processInfo.environment["MINUTIAE_ASR_TRIM"] != "0"

    public let channel: Channel
    private let engine: AsrEngine
    private let ring: RingBuffer
    private let indexAllocator: SegmentIndexAllocator
    private let emit: @Sendable (Segment) -> Void
    private let sampleRate: Int
    private let blockSamples: Int
    private let context: AsrContext
    /// Injectable so tests do not sit through the real wait.
    private let stopReadyTimeout: Double

    /// Session time of a known absolute sample index. A new anchor is added
    /// whenever the capture source skips (its buffers stop arriving), so time
    /// stays exact across a hole instead of sliding earlier by its length.
    private struct TimeAnchor {
        var absSample: Int
        var time: Double
    }

    private struct State {
        /// Absolute index of the ring's oldest buffered sample.
        var headAbs = 0
        /// Absolute index the next appended sample will take.
        var nextAbs = 0
        /// Oldest first; the last one at or before `headAbs` is the live one.
        var anchors: [TimeAnchor] = []
        /// Ring overflow already folded into `headAbs`.
        var accountedDrops = 0
        /// Consecutive silence consumed since the last utterance.
        var silenceRun = 0.0
        var emittedSegments = 0
        /// Pump invocations chain onto this task — strictly serial, and
        /// finish() awaiting the chain runs after all pending pumps.
        var pumpChain: Task<Void, Never> = Task {}
        /// Set once so a stop during warm-up can report what it abandoned.
        var heldForWarmup = false
        /// `nextAbs` at the last scan performed while the engine was not ready.
        var lastHeldScanAbs = 0
        /// Level of each whole block from the ring's head. Kept across pumps:
        /// re-measuring the whole buffer every 100 ms would cost more CPU than
        /// the rest of the capture path put together.
        var blocks: [Double] = []
    }

    private let stateLock = NSLock()
    private var state = State()

    @discardableResult
    private func withState<R>(_ body: (inout State) -> R) -> R {
        stateLock.lock(); defer { stateLock.unlock() }
        return body(&state)
    }

    public init(channel: Channel,
                engine: AsrEngine,
                indexAllocator: SegmentIndexAllocator,
                sampleRate: Int = Int(Resampler.asrSampleRate),
                blockSeconds: Double = WindowedTranscriber.blockSeconds,
                bufferCapacitySeconds: Double = 30,
                stopReadyTimeout: Double = WindowedTranscriber.stopReadyTimeoutSeconds,
                emit: @escaping @Sendable (Segment) -> Void) {
        self.channel = channel
        self.engine = engine
        self.indexAllocator = indexAllocator
        self.sampleRate = sampleRate
        self.blockSamples = max(1, Int(blockSeconds * Double(sampleRate)))
        self.stopReadyTimeout = stopReadyTimeout
        self.ring = RingBuffer(capacity: Int(bufferCapacitySeconds * Double(sampleRate)))
        self.emit = emit
        self.context = engine.makeContext()
    }

    public var segmentsEmitted: Int {
        withState { $0.emittedSegments }
    }

    /// Windows lost to ring overflow (ASR slower than realtime, or a warm-up
    /// longer than the ring). Reported in session_stopped stats.
    public var droppedWindows: Int {
        ring.droppedSamples / max(Int(Self.maxWindowSeconds * Double(sampleRate)), 1)
    }

    // MARK: - Input

    /// Feed resampled samples. `firstSampleTime` is the session-relative time
    /// of samples[0] (from SessionClock); it anchors the stream, and a jump in
    /// it means the source stopped delivering for a while.
    public func feed(samples: [Float], firstSampleTime: Double) {
        guard !samples.isEmpty else { return }
        let wake = withState { state -> Bool in
            let expected = expectedTime(&state, forAbs: state.nextAbs)
            if expected == nil {
                // First samples ever: sample 0 is session time `firstSampleTime`.
                state.anchors = [TimeAnchor(absSample: state.nextAbs,
                                            time: max(0, firstSampleTime))]
            } else if let expected, firstSampleTime - expected >= Self.discontinuitySeconds {
                // The source went away and came back. Anchor the resumed audio
                // at its real time; the pump will not let an utterance span the
                // seam, and the decoder context is reset when it crosses it.
                log(String(format: "%@ capture gap: %.1f s (stream re-anchored)",
                           channel.rawValue, firstSampleTime - expected))
                state.anchors.append(TimeAnchor(absSample: state.nextAbs,
                                                time: firstSampleTime))
            }
            state.nextAbs += samples.count
            // One pump per block of new audio is enough; without this every
            // capture buffer chained a Task — ~94/s from the system tap alone.
            return (state.nextAbs - state.headAbs) >= blockSamples
        }
        ring.append(samples)
        guard wake else { return }
        _ = enqueuePump(drainPartial: false)
    }

    /// The engine finished loading: transcribe whatever was held meanwhile.
    public func engineBecameReady() {
        _ = enqueuePump(drainPartial: false)
    }

    /// Drain the final partial utterance on session stop. Waits for all pending
    /// work (and the tail) to finish transcribing.
    public func finish() async {
        await enqueuePump(drainPartial: true).value
    }

    private func enqueuePump(drainPartial: Bool) -> Task<Void, Never> {
        withState { state in
            let previous = state.pumpChain
            let task = Task {
                await previous.value
                await self.pump(drainPartial: drainPartial)
            }
            state.pumpChain = task
            return task
        }
    }

    // MARK: - Pump

    private func pump(drainPartial: Bool) async {
        if drainPartial, !engine.isReady {
            await awaitEngineReady(timeout: stopReadyTimeout)
        }
        // While the models load, every capture buffer still wakes a pump that
        // can only decide to keep waiting. Scanning the whole ring ~94 times a
        // second to reach that conclusion is pure waste — once a second is
        // enough to keep trimming silence out of the held audio.
        if !drainPartial, !engine.isReady {
            let skip = withState { state -> Bool in
                guard state.nextAbs - state.lastHeldScanAbs < self.sampleRate else {
                    state.lastHeldScanAbs = state.nextAbs
                    return false
                }
                return true
            }
            if skip { return }
        }
        while true {
            syncOverflow()
            let available = ring.availableSamples
            guard available > 0 else { return }

            let limit = boundaryLimit(available: available)
            let energies = scanNewBlocks(available: available)

            let plan = Self.plan(blockDbfs: energies,
                                 blockSamples: blockSamples,
                                 available: available,
                                 limit: limit,
                                 drain: drainPartial,
                                 params: params)

            switch plan {
            case .wait:
                return

            case .trim(let samples):
                ring.advance(by: samples)
                withState { state in
                    self.dropBlocks(&state, consumed: samples)
                    state.headAbs += samples
                    state.silenceRun += Double(samples) / Double(self.sampleRate)
                    self.pruneAnchors(&state)
                    if state.silenceRun >= Self.contextResetSilenceSeconds {
                        self.context.reset()
                    }
                }

            case .emit(let samples):
                // The audio stays in the ring until the engine can actually
                // transcribe it. Holding is the whole point: a window popped
                // before the models finish loading is a window lost.
                guard engine.isReady else {
                    withState { state in
                        if !state.heldForWarmup {
                            state.heldForWarmup = true
                            log("\(self.channel.rawValue): holding audio until ASR models are ready")
                        }
                    }
                    return
                }
                guard let window = ring.popWindow(count: samples, advance: samples) else { return }
                let startTime = withState { state -> Double in
                    let t = self.timeOf(&state, abs: state.headAbs)
                    self.dropBlocks(&state, consumed: samples)
                    state.headAbs += samples
                    state.silenceRun = 0
                    // Crossing a discontinuity: the next utterance does not
                    // continue this sentence.
                    let crossed = state.anchors.contains { $0.absSample > 0
                        && $0.absSample <= state.headAbs
                        && $0.absSample > state.headAbs - samples }
                    self.pruneAnchors(&state)
                    if crossed { self.context.reset() }
                    return t
                }
                await process(window: window, startTime: startTime)
            }
        }
    }

    /// Extends the cached block envelope to cover everything buffered, and
    /// returns it. Only blocks never measured before cost anything.
    private func scanNewBlocks(available: Int) -> [Double] {
        withState { state in
            let have = state.blocks.count
            let want = available / self.blockSamples
            if want > have {
                let fresh = self.ring.blockMeanSquares(blockSize: self.blockSamples,
                                                       startOffset: have * self.blockSamples,
                                                       maxBlocks: want - have)
                state.blocks.append(contentsOf: fresh.map { Self.dbfs(meanSquare: Double($0)) })
            }
            return state.blocks
        }
    }

    /// Keeps the envelope aligned with the ring after `consumed` samples are
    /// taken off the front. A cut that does not land on a block boundary
    /// (a capture seam, or the tail at stop) invalidates the grid.
    private func dropBlocks(_ state: inout State, consumed: Int) {
        guard consumed % blockSamples == 0 else {
            state.blocks.removeAll(keepingCapacity: true)
            return
        }
        let n = min(consumed / blockSamples, state.blocks.count)
        if n > 0 { state.blocks.removeFirst(n) }
    }

    private var params: Params {
        Params(guardBlocks: blocks(Self.leadGuardSeconds),
               endSilenceBlocks: max(1, blocks(Self.endSilenceSeconds)),
               maxSamples: Int(Self.maxWindowSeconds * Double(sampleRate)),
               cutSearchBlocks: max(1, blocks(Self.cutSearchSeconds)),
               minSamples: Int(Self.minUtteranceSeconds * Double(sampleRate)),
               gateDbfs: Self.silenceGateDbfs)
    }

    private func blocks(_ seconds: Double) -> Int {
        max(0, Int((seconds * Double(sampleRate) / Double(blockSamples)).rounded()))
    }

    /// Folds ring overflow into the time base. The ring drops its OLDEST
    /// samples when the producer outruns the consumer, so the head jumps
    /// forward by exactly that many samples; without this every later
    /// timestamp would be early by the dropped duration.
    private func syncOverflow() {
        let dropped = ring.droppedSamples
        withState { state in
            let delta = dropped - state.accountedDrops
            guard delta > 0 else { return }
            state.accountedDrops = dropped
            state.blocks.removeAll(keepingCapacity: true)
            state.headAbs += delta
            self.pruneAnchors(&state)
            self.context.reset()
        }
    }

    /// The furthest this utterance may extend: a discontinuity anchor ahead of
    /// the head caps it, so no utterance ever spans a capture hole.
    private func boundaryLimit(available: Int) -> Int {
        withState { state in
            let head = state.headAbs
            let next = state.anchors.first { $0.absSample > head }
            guard let next else { return available }
            return max(0, min(available, next.absSample - head))
        }
    }

    private func expectedTime(_ state: inout State, forAbs abs: Int) -> Double? {
        guard !state.anchors.isEmpty else { return nil }
        return timeOf(&state, abs: abs)
    }

    private func timeOf(_ state: inout State, abs: Int) -> Double {
        var anchor = state.anchors.first ?? TimeAnchor(absSample: 0, time: 0)
        for a in state.anchors where a.absSample <= abs { anchor = a }
        return anchor.time + Double(abs - anchor.absSample) / Double(sampleRate)
    }

    /// Keep only the live anchor and any still ahead of the head.
    private func pruneAnchors(_ state: inout State) {
        guard state.anchors.count > 1 else { return }
        var live = 0
        for (i, a) in state.anchors.enumerated() where a.absSample <= state.headAbs { live = i }
        if live > 0 { state.anchors.removeFirst(live) }
    }

    private func awaitEngineReady(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !engine.isReady, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !engine.isReady {
            let seconds = Double(ring.availableSamples) / Double(sampleRate)
            log(String(format: "%@: ASR models still loading at stop — %.1f s of audio not transcribed",
                       channel.rawValue, seconds))
        }
    }

    // MARK: - Transcription

    private func process(window: [Float], startTime: Double) async {
        // The segmenter only emits utterances that opened on a block above the
        // gate, but the drain path and forced cuts can still produce a quiet
        // tail. Silence produces zero segments — the hard guarantee.
        guard Self.rmsDbfs(window) >= Self.silenceGateDbfs else { return }

        let span = Self.trimEnabled
            ? Self.speechSpan(in: window, sampleRate: sampleRate)
            : 0..<window.count
        let asrInput = span.count == window.count ? window : Array(window[span])

        let result: AsrResult
        do {
            result = try await engine.transcribe(window: asrInput, sampleRate: sampleRate,
                                                 context: context)
        } catch {
            log("transcribe failed (\(channel.rawValue)): \(error)")
            // Whatever the decoder was carrying is now unreliable.
            context.reset()
            return
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Carrying decoder state means a short utterance after a pause can
        // decode to nothing but the punctuation that closed the previous
        // sentence. A segment of "." is noise in the transcript.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }

        // Timestamps describe the audio actually transcribed, so the trim
        // offset shifts them rather than being silently ignored.
        let base = startTime + Double(span.lowerBound) / Double(sampleRate)
        let spanSeconds = Double(span.count) / Double(sampleRate)
        var t0 = base
        var t1 = base + spanSeconds
        // Parakeet reports per-token timings; they place the words inside the
        // utterance far more tightly than its outer bounds do.
        if let first = result.tokenTimings.first, let last = result.tokenTimings.max(by: { $0.endS < $1.endS }) {
            t0 = base + max(0, min(first.startS, spanSeconds))
            t1 = base + max(0, min(last.endS, spanSeconds))
            if t1 <= t0 { t1 = min(base + spanSeconds, t0 + 0.01) }
        }

        let segment = Segment(
            idx: indexAllocator.allocate(),
            channel: channel,
            t0: (t0 * 100).rounded() / 100,
            t1: (t1 * 100).rounded() / 100,
            text: text,
            confidence: result.confidence,
            isFinal: true,
            engine: engine.id)

        withState { $0.emittedSegments += 1 }
        emit(segment)
    }

    // MARK: - Segmentation (pure, unit-tested)

    struct Params {
        var guardBlocks: Int
        var endSilenceBlocks: Int
        var maxSamples: Int
        var cutSearchBlocks: Int
        var minSamples: Int
        var gateDbfs: Double
    }

    enum Plan: Equatable {
        /// Nothing to do until more audio arrives.
        case wait
        /// Discard this many samples of leading silence.
        case trim(samples: Int)
        /// Pop and transcribe this many samples.
        case emit(samples: Int)
    }

    /// Decides what to do with the currently buffered audio.
    ///
    /// - Parameters:
    ///   - blockDbfs: level of each whole block from the oldest sample.
    ///   - available: total buffered samples (may include a partial block).
    ///   - limit: samples until the next capture discontinuity, or `available`.
    ///   - drain: session stop — emit the tail rather than waiting for a pause.
    static func plan(blockDbfs: [Double], blockSamples: Int, available: Int,
                     limit: Int, drain: Bool, params p: Params) -> Plan {
        let n = blockDbfs.count
        let atBoundary = limit < available
        func loud(_ i: Int) -> Bool { blockDbfs[i] >= p.gateDbfs }

        guard let firstLoud = (0..<n).first(where: loud) else {
            // All silence. Keep the guard so a word starting in the next
            // buffer still has its onset; drop the rest in place.
            if drain { return available > 0 ? .trim(samples: available) : .wait }
            let keep = p.guardBlocks * blockSamples
            return available > keep ? .trim(samples: available - keep) : .wait
        }

        if firstLoud > p.guardBlocks {
            return .trim(samples: (firstLoud - p.guardBlocks) * blockSamples)
        }

        // An utterance is open, starting at sample 0 of the buffer.
        let bounded = atBoundary ? min(n, limit / blockSamples) : n
        var lastLoud = firstLoud
        var i = firstLoud + 1
        while i < bounded {
            if loud(i) {
                lastLoud = i
            } else if i - lastLoud >= p.endSilenceBlocks {
                // The speaker stopped: cut just after the last speech, plus
                // the guard, so a soft word ending is not clipped.
                let end = min(lastLoud + 1 + p.guardBlocks, bounded)
                return .emit(samples: min(end * blockSamples, limit))
            }
            if (i + 1) * blockSamples >= p.maxSamples {
                return .emit(samples: forcedCut(blockDbfs: blockDbfs, blockSamples: blockSamples,
                                                endBlock: i + 1, firstLoud: firstLoud,
                                                limit: limit, params: p))
            }
            i += 1
        }

        // Ran out of audio without a pause.
        if atBoundary, limit > 0 {
            return .emit(samples: limit)   // never span a capture hole
        }
        if drain, available > 0 {
            return .emit(samples: available)
        }
        return .wait
    }

    /// A cut the speaker never gave us: place it at the end of the quietest
    /// block in the recent past, so the seam lands where the audio is weakest
    /// — and on a block boundary, so the cached envelope survives it.
    private static func forcedCut(blockDbfs: [Double], blockSamples: Int, endBlock: Int,
                                  firstLoud: Int, limit: Int, params p: Params) -> Int {
        let lowest = max(firstLoud + 1, endBlock - p.cutSearchBlocks)
        var best = endBlock - 1
        if lowest < endBlock {
            var bestLevel = Double.greatestFiniteMagnitude
            for i in lowest..<endBlock where blockDbfs[i] < bestLevel {
                bestLevel = blockDbfs[i]
                best = i
            }
        }
        let cut = (best + 1) * blockSamples
        return max(p.minSamples, min(cut, min(endBlock * blockSamples, limit)))
    }

    // MARK: - Pure helpers (unit-tested)

    public static func rmsDbfs(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var meanSquare: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_measqv(buf.baseAddress!, 1, &meanSquare, vDSP_Length(buf.count))
        }
        return dbfs(meanSquare: Double(meanSquare))
    }

    /// Shared conversion, so the ring's in-place gate and the array-based gate
    /// can never disagree about what counts as silence.
    public static func dbfs(meanSquare: Double) -> Double {
        let rms = meanSquare.squareRoot()
        guard rms > 0 else { return -120 }
        return max(-120, 20 * log10(rms))
    }

    /// Range of `window` from the first to the last 100 ms block above
    /// `trimGateDbfs`, expanded by `trimGuardSeconds` on each side. Interior
    /// quiet is always kept — only leading and trailing silence is dropped.
    public static func speechSpan(in window: [Float], sampleRate: Int) -> Range<Int> {
        let block = max(1, sampleRate / 10)
        guard window.count > 2 * block else { return 0..<window.count }
        var first = -1
        var last = -1
        window.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i < buf.count {
                let n = min(block, buf.count - i)
                var mean: Float = 0
                vDSP_measqv(base + i, 1, &mean, vDSP_Length(n))
                if dbfs(meanSquare: Double(mean)) >= trimGateDbfs {
                    if first < 0 { first = i }
                    last = i + n
                }
                i += n
            }
        }
        // Nothing above even the trim gate: leave the window alone rather than
        // inventing an empty span.
        guard first >= 0, last > first else { return 0..<window.count }
        let guardSamples = Int(trimGuardSeconds * Double(sampleRate))
        return max(0, first - guardSamples)..<min(window.count, last + guardSamples)
    }
}
