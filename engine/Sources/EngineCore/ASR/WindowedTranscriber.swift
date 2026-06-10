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

/// Per-channel windowed transcription over a ring buffer of 16 kHz mono
/// samples. Windows are `windowSeconds` long with `hopSeconds` advance
/// (1 s overlap with the 5 s / 4 s defaults).
///
/// Hard product guarantee: an RMS silence gate skips windows below
/// `silenceGateDbfs` BEFORE ASR — silence produces zero segments and zero
/// ANE work.
///
/// Overlap de-dup: the leading tokens of each window that match the trailing
/// tokens of the previous window's text (longest suffix/prefix match on
/// normalized tokens) are trimmed.
///
/// M1 simplification (documented choice): every deduped window is emitted as
/// `final: true` immediately. The protocol allows non-final re-emission but
/// does not require it; immediate-final is simpler and loses nothing at a
/// 5 s window size.
public final class WindowedTranscriber: @unchecked Sendable {
    public static let defaultWindowSeconds = 5.0
    public static let defaultHopSeconds = 4.0
    /// Tunable. dBFS; windows quieter than this never reach the ASR.
    public static let silenceGateDbfs: Double = -50.0

    public let channel: Channel
    private let engine: AsrEngine
    private let ring: RingBuffer
    private let indexAllocator: SegmentIndexAllocator
    private let emit: @Sendable (Segment) -> Void
    private let sampleRate: Int
    private let windowSamples: Int
    private let hopSamples: Int

    private struct State {
        var previousTailTokens: [String] = []
        /// Stream position (in samples) of the start of the next window.
        var streamPosition = 0
        /// Session-relative seconds of stream sample 0 (set on first samples).
        var streamT0: Double?
        var emittedSegments = 0
        /// Pump invocations chain onto this task — strictly serial, and
        /// finish() awaiting the chain runs after all pending pumps.
        var pumpChain: Task<Void, Never> = Task {}
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
                windowSeconds: Double = WindowedTranscriber.defaultWindowSeconds,
                hopSeconds: Double = WindowedTranscriber.defaultHopSeconds,
                bufferCapacitySeconds: Double = 30,
                emit: @escaping @Sendable (Segment) -> Void) {
        self.channel = channel
        self.engine = engine
        self.indexAllocator = indexAllocator
        self.sampleRate = sampleRate
        self.windowSamples = Int(windowSeconds * Double(sampleRate))
        self.hopSamples = Int(hopSeconds * Double(sampleRate))
        self.ring = RingBuffer(capacity: Int(bufferCapacitySeconds * Double(sampleRate)))
        self.emit = emit
    }

    public var segmentsEmitted: Int {
        withState { $0.emittedSegments }
    }

    /// Windows lost to ring overflow (ASR slower than realtime).
    public var droppedWindows: Int {
        ring.droppedSamples / max(windowSamples, 1)
    }

    /// Feed resampled samples. `firstSampleTime` is the session-relative time
    /// of samples[0] (from SessionClock); used once to anchor the stream.
    public func feed(samples: [Float], firstSampleTime: Double) {
        guard !samples.isEmpty else { return }
        withState { state in
            if state.streamT0 == nil {
                state.streamT0 = max(0, firstSampleTime)
            }
        }
        ring.append(samples)
        _ = enqueuePump(drainPartial: false)
    }

    /// Drain the final partial window on session stop. Waits for all pending
    /// windows (and the partial tail) to finish transcribing.
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

    private func pump(drainPartial: Bool) async {
        while let window = ring.popWindow(count: windowSamples, advance: hopSamples) {
            await process(window: window, sampleCount: windowSamples)
            advanceStream(by: hopSamples)
        }
        if drainPartial {
            let rest = ring.drainAll()
            // Require at least 0.5 s of tail audio to bother the ASR.
            if rest.count >= sampleRate / 2 {
                await process(window: rest, sampleCount: rest.count)
            }
            advanceStream(by: rest.count)
        }
    }

    private func advanceStream(by samples: Int) {
        withState { $0.streamPosition += samples }
    }

    private func process(window: [Float], sampleCount: Int) async {
        // RMS silence gate — zero segments during silence is a hard guarantee.
        guard Self.rmsDbfs(window) >= Self.silenceGateDbfs else { return }

        let result: AsrResult
        do {
            result = try await engine.transcribe(window: window, sampleRate: sampleRate)
        } catch {
            log("transcribe failed (\(channel.rawValue)): \(error)")
            return
        }

        let (t0Base, prevTail) = withState { state in
            ((state.streamT0 ?? 0) + Double(state.streamPosition) / Double(sampleRate),
             state.previousTailTokens)
        }

        let tokens = Self.normalizedTokens(result.text)
        guard !tokens.isEmpty else { return }

        let trimmed = Self.trimOverlap(tokens: tokens, previousTail: prevTail)

        withState { $0.previousTailTokens = Array(tokens.suffix(12)) }

        guard !trimmed.isEmpty else { return }
        let text = trimmed.joined(separator: " ")

        let t1 = t0Base + Double(sampleCount) / Double(sampleRate)
        let segment = Segment(
            idx: indexAllocator.allocate(),
            channel: channel,
            t0: (t0Base * 100).rounded() / 100,
            t1: (t1 * 100).rounded() / 100,
            text: text,
            confidence: result.confidence,
            isFinal: true,
            engine: engine.id)

        withState { $0.emittedSegments += 1 }
        emit(segment)
    }

    // MARK: - Pure helpers (unit-tested)

    public static func rmsDbfs(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -120 }
        return max(-120, 20 * log10(rms))
    }

    public static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    /// Removes the longest leading run of `tokens` that matches a trailing run
    /// of `previousTail` (the 1 s window overlap re-recognizes the same words).
    public static func trimOverlap(tokens: [String], previousTail: [String]) -> [String] {
        guard !tokens.isEmpty, !previousTail.isEmpty else { return tokens }
        let maxOverlap = min(tokens.count, previousTail.count)
        var best = 0
        for k in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(previousTail.suffix(k)) == Array(tokens.prefix(k)) {
                best = k
                break
            }
        }
        return Array(tokens.dropFirst(best))
    }
}
