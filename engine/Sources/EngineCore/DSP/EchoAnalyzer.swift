import Accelerate
import Foundation

/// Cross-channel acoustic echo *suppressor* (not a canceller).
///
/// When the user is on speakers, the far-end audio the `them` process tap
/// captures electronically also reaches the mic acoustically, so the same
/// speech is transcribed on both channels. The tap therefore gives us a clean
/// reference of exactly what the speakers played, which is what suppression
/// needs.
///
/// Why suppression rather than an NLMS canceller:
///  - the two streams come from independent Core Audio clocks (mic device vs
///    output device) and drift by tens of ppm; an adaptive filter tail tracks
///    that poorly, an energy-envelope method ignores it entirely;
///  - speaker nonlinearity and mid-meeting volume changes break the linear
///    model NLMS assumes;
///  - the goal is not full-duplex clean audio, it is "far-end bleed falls
///    below the ASR's RMS gate", which ~20 dB of suppression achieves.
///
/// Feed both channels' 16 kHz mono streams via `pushFar` / `pushNear`; gains
/// land in the supplied `GainTimeline` on the near channel's frame grid.
///
/// SAFETY: below the confidence threshold (headphones — no acoustic path, so
/// no envelope correlation) the emitted gain is *exactly* 1.0. The failure
/// mode is always "some echo leaks through", never "the user's voice is
/// destroyed".
///
/// DISENGAGEMENT is asymmetric: engaging needs fresh correlation evidence, but
/// once locked, confidence only decays on windows that are clean (far end
/// active, near end quiet) yet still fail to correlate — a genuine route
/// change. Windows contaminated by near-end speech, and windows with no far
/// audio at all, prove nothing about the acoustic path and leave the lock
/// alone. Decaying on those disengaged the suppressor whenever the user spoke
/// for a few sentences, snapping the gain to unity mid-meeting.
///
/// CONVERGENCE: locking the delay needs ~1 s of correlatable envelope plus the
/// lag search range, so suppression engages roughly 2 s into a session and
/// echo passes through until then. Measured on real speech: unsuppressed for
/// ~2 s, then ~35 dB down. In practice at most the opening sentence of a
/// meeting can still be transcribed on both channels.
public final class EchoAnalyzer: @unchecked Sendable {

    // MARK: - Tuning

    public static let sampleRate: Double = Resampler.asrSampleRate   // 16 kHz
    static let frameSize = 512          // 32 ms
    static let hopSize = 256            // 16 ms
    static let log2n: vDSP_Length = 9   // 2^9 == frameSize
    static let bins = frameSize / 2

    /// 8 roughly log-spaced bands, in Hz. Per-band coupling lets a near-end
    /// voice in one band survive while echo-dominated bands are suppressed.
    static let bandEdgesHz: [Double] = [0, 300, 600, 1000, 1600, 2400, 3600, 5500, 8000]
    static var bandCount: Int { bandEdgesHz.count - 1 }

    /// Acoustic delay search range: 0…512 ms (lags 0…32 frames).
    static let maxLagFrames = 32
    /// Correlate over 4 s of envelope, re-estimating every 1 s.
    static let corrWindowFrames = 250
    static let corrIntervalFrames = 62
    /// Minimum envelope needed for a first estimate (1 s). Every second before
    /// the suppressor engages is a second of echo transcribed twice, so the
    /// first lock uses the shortest window that still correlates reliably;
    /// later estimates use the full 4 s window and refine it. A short window is
    /// noisier, but the accept threshold and prominence margin still gate it.
    static let corrMinFrames = 62
    /// Envelope history must cover the correlation window plus the lag search.
    static let historyFrames = 1024     // ≈ 16 s

    static let couplingInit: Float = 0.05       // −26 dB
    static let couplingStep: Float = 0.05
    static let couplingMin: Float = 1e-4
    static let couplingMax: Float = 1.0
    static let overSubtraction: Float = 1.5

    /// Echo-only floor, −34 dB. Must be deep enough that real-world bleed
    /// (≈ −29 dBFS at the mic) lands well under the transcriber's −50 dBFS
    /// silence gate — at −20 dB it sat right on the threshold and was still
    /// transcribed.
    ///
    /// Going this deep is safe because the floor is NOT what protects the
    /// user's voice: the per-band residual `E_near − 1.5·Ê` is. The gain only
    /// reaches the floor when the near signal is fully explained by the echo
    /// prediction; any near-end speech leaves residual in its own bands and
    /// pulls the energy-weighted gain back up well above it.
    static let gainFloor: Float = 0.02          // −34 dB
    static let gainFloorDoubleTalk: Float = 0.7 // −3 dB — protects near speech
    /// Instant attack (start suppressing), slow release (stop suppressing).
    ///
    /// Attack is deliberately instantaneous: any ramp lets the onset of every
    /// far-end burst leak through at partial gain, and onsets are exactly where
    /// speech energy is highest. There is no click risk — the timeline
    /// interpolates between frame centres and the delay line ramps within
    /// 64-sample sub-blocks, so the transition still spans a 16 ms hop.
    ///
    /// Release is slower, so the gain does not bounce back up during short
    /// inter-syllable pauses. It must still release eventually: if the far end
    /// stops, the user may start speaking into that gap and must not be
    /// attenuated. Double-talk bypasses it (see `gainForNearFrame`).
    static let alphaAttack: Float = 0.0         // instant
    static let alphaRelease: Float = 0.96       // ≈ 400 ms

    static let corrAcceptThreshold: Float = 0.6
    /// Additive margin the correlation peak must beat the runner-up by.
    static let corrProminence: Float = 0.08
    static let engageThreshold: Float = 0.5
    static let confidenceDecayPerEstimate: Float = 0.9
    static let energyFloor: Float = 1e-9
    static let eps: Float = 1e-12
    /// Near energy this many× the predicted echo ⇒ the user is talking too.
    static let doubleTalkRatio: Float = 3.0
    /// Far end counts as "playing" above this fraction of its decaying peak
    /// (≈ −40 dB). Scale-free, since FFT band energies are unnormalized.
    static let farActiveFraction: Float = 1e-4
    static let farPeakDecay: Float = 0.999
    /// Above this fraction of double-talk frames in a correlation window, a
    /// REJECTED estimate does not decay confidence: the user talking is why
    /// the correlation failed, not a vanished acoustic path.
    static let doubleTalkSkipDecayFraction: Float = 0.1
    /// Above this fraction, an ACCEPTED estimate at the locked lag means the
    /// "double-talk" is actually echo: real near speech decorrelates the
    /// envelopes, so a window that both correlates and was ~all flagged
    /// double-talk is a false latch — coupling is far below reality.
    static let doubleTalkFalseLatchFraction: Float = 0.8
    /// While the reseed countdown runs, coupling adapts even during
    /// double-talk and without the 4× outlier gate. This is the only way back
    /// once the true coupling jumps more than 4× above the estimate (speaker
    /// volume up during real double-talk): the freeze and the gate otherwise
    /// hold the stale value forever, pure echo keeps reading as "user
    /// talking", and the gain sits near unity for the rest of the meeting.
    static let couplingReseedFrames = corrIntervalFrames
    /// Per-estimate tracing via MINUTIAE_ECHO_DEBUG=1 — the tool for
    /// diagnosing "why didn't it engage?" in the field.
    static let debugEstimates = ProcessInfo.processInfo.environment["MINUTIAE_ECHO_DEBUG"] == "1"

    // MARK: - State

    private let timeline: GainTimeline
    private let lock = NSLock()

    private var fftSetup: FFTSetup?
    private var hann: [Float]
    private var bandBinRanges: [(Int, Int)]
    // Reused FFT scratch (allocated once; DSPSplitComplex needs stable storage).
    private var realp: UnsafeMutablePointer<Float>
    private var imagp: UnsafeMutablePointer<Float>
    private var windowed: UnsafeMutablePointer<Float>
    private var mags: UnsafeMutablePointer<Float>

    /// Per-channel framing state.
    private struct Stream {
        var pending: [Float] = []
        var t0: Double?
        var framesEmitted = 0
    }
    private var near = Stream()
    private var far = Stream()

    /// Circular per-frame stores, indexed by `frameNumber % historyFrames`.
    private var farBands: [Float]     // historyFrames * bandCount
    private var farLog: [Float]
    private var farNewest = -1
    private var nearLog: [Float]
    private var nearNewest = -1

    /// Whether each near frame was flagged double-talk, on the same circular
    /// grid as `nearLog`. Read by `estimateDelay` to classify a window as
    /// clean or contaminated.
    private var doubleTalkHistory: [Bool]
    private var couplingReseedRemaining = 0

    private var coupling: [Float]
    private var smoothedGain: Float = 1.0
    private var lagFrames = 0
    /// Sub-frame-refined lag; `gainForNearFrame` blends the two frames it falls between.
    private var lagFractional: Float = 0
    private var recentLags: [Int] = []
    private var framesSinceEstimate = 0
    private var confidenceValue: Float = 0
    private var engagedValue = false
    private var doubleTalkEnergyRatio: Float = 1
    private var farPeak: Float = 0

    // MARK: - Public read-only state (logging / gating)

    public var confidence: Float { lock.lock(); defer { lock.unlock() }; return confidenceValue }
    public var isEngaged: Bool { lock.lock(); defer { lock.unlock() }; return engagedValue }
    public var estimatedDelaySeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(lagFractional) * Double(Self.hopSize) / Self.sampleRate
    }

    /// Per-band coupling estimate — exposed for tests and log diagnostics.
    var debugCoupling: [Float] { lock.lock(); defer { lock.unlock() }; return coupling }

    public init(timeline: GainTimeline) {
        self.timeline = timeline
        self.fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))

        var w = [Float](repeating: 0, count: Self.frameSize)
        vDSP_hann_window(&w, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_NORM))
        self.hann = w

        let hzPerBin = Self.sampleRate / Double(Self.frameSize)
        self.bandBinRanges = (0..<Self.bandCount).map { b in
            let lo = max(0, Int((Self.bandEdgesHz[b] / hzPerBin).rounded()))
            let hi = min(Self.bins, max(lo + 1, Int((Self.bandEdgesHz[b + 1] / hzPerBin).rounded())))
            return (lo, hi)
        }

        self.realp = .allocate(capacity: Self.bins)
        self.imagp = .allocate(capacity: Self.bins)
        self.windowed = .allocate(capacity: Self.frameSize)
        self.mags = .allocate(capacity: Self.bins)
        self.realp.initialize(repeating: 0, count: Self.bins)
        self.imagp.initialize(repeating: 0, count: Self.bins)
        self.windowed.initialize(repeating: 0, count: Self.frameSize)
        self.mags.initialize(repeating: 0, count: Self.bins)

        self.farBands = [Float](repeating: 0, count: Self.historyFrames * Self.bandCount)
        self.farLog = [Float](repeating: -20, count: Self.historyFrames)
        self.nearLog = [Float](repeating: -20, count: Self.historyFrames)
        self.doubleTalkHistory = [Bool](repeating: false, count: Self.historyFrames)
        self.coupling = [Float](repeating: Self.couplingInit, count: Self.bandCount)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        realp.deallocate()
        imagp.deallocate()
        windowed.deallocate()
        mags.deallocate()
    }

    // MARK: - Input

    /// Far reference (`them`) — 16 kHz mono, `time` is the session-relative
    /// time of `samples[0]`.
    public func pushFar(_ samples: [Float], at time: Double) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if far.t0 == nil { far.t0 = time }
        padForGap(&far, arrivingAt: time, label: "far")
        far.pending.append(contentsOf: samples)
        drainFarFrames()
    }

    /// Near signal (`me`) — 16 kHz mono. Emits one gain per frame.
    public func pushNear(_ samples: [Float], at time: Double) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if near.t0 == nil { near.t0 = time }
        padForGap(&near, arrivingAt: time, label: "near")
        near.pending.append(contentsOf: samples)
        drainNearFrames()
    }

    /// Matches the writer's rule for "this source stopped delivering".
    static let gapThresholdSeconds = 0.25
    /// Longest hole worth filling. Beyond this the whole history is stale
    /// anyway, so the stream is re-anchored instead.
    private static let maxPadSeconds = Double(historyFrames * hopSize) / sampleRate

    /// A stream's sample index doubles as its clock: frame `n` is at
    /// `t0 + n * hop / rate`. That holds only while buffers keep arriving. If a
    /// source stops (the system tap's IOProc does not run while the output
    /// device is idle) and resumes, every later frame would be timed early by
    /// the length of the hole, sliding the delay estimate with it. Fill short
    /// holes with silence, and re-anchor `t0` past long ones.
    private func padForGap(_ stream: inout Stream, arrivingAt time: Double, label: String) {
        guard let t0 = stream.t0 else { return }
        let consumed = Double(stream.framesEmitted * Self.hopSize) / Self.sampleRate
        let expected = t0 + consumed + Double(stream.pending.count) / Self.sampleRate
        let gap = time - expected
        guard gap >= Self.gapThresholdSeconds else { return }
        let padSeconds = min(gap, Self.maxPadSeconds)
        let padSamples = Int((padSeconds * Self.sampleRate).rounded())
        if padSamples > 0 {
            stream.pending.append(contentsOf: [Float](repeating: 0, count: padSamples))
        }
        // Whatever is left of the hole is absorbed by moving the stream's
        // origin forward. Everything still in the history is silence by then,
        // so no frame that a correlation can use is mis-timed by the shift.
        let remainder = gap - padSeconds
        if remainder > 0 { stream.t0 = t0 + remainder }
        if Self.debugEstimates {
            log(String(format: "echo: %@ gap %.2f s (padded %.2f s, shifted %.2f s)",
                       label, gap, padSeconds, remainder))
        }
    }

    // MARK: - Framing

    private func drainFarFrames() {
        while far.pending.count >= Self.frameSize {
            let frame = Array(far.pending[0..<Self.frameSize])
            let n = far.framesEmitted
            let bands = bandEnergies(frame)
            let slot = ((n % Self.historyFrames) + Self.historyFrames) % Self.historyFrames
            for b in 0..<Self.bandCount {
                farBands[slot * Self.bandCount + b] = bands[b]
            }
            farLog[slot] = log(bands.reduce(0, +) + Self.eps)
            farNewest = n
            far.framesEmitted += 1
            far.pending.removeFirst(Self.hopSize)
        }
    }

    private func drainNearFrames() {
        while near.pending.count >= Self.frameSize {
            let frame = Array(near.pending[0..<Self.frameSize])
            let n = near.framesEmitted
            let bands = bandEnergies(frame)
            let slot = ((n % Self.historyFrames) + Self.historyFrames) % Self.historyFrames
            nearLog[slot] = log(bands.reduce(0, +) + Self.eps)
            nearNewest = n

            framesSinceEstimate += 1
            if framesSinceEstimate >= Self.corrIntervalFrames {
                framesSinceEstimate = 0
                estimateDelay()
            }

            let g = gainForNearFrame(index: n, bands: bands)
            // Stamp at the analysis window's CENTER: the gain characterizes the
            // whole 32 ms frame, so anchoring it at the start would bias every
            // interpolated sample by half a frame.
            let t = (near.t0 ?? 0)
                + (Double(n) * Double(Self.hopSize) + Double(Self.frameSize) / 2) / Self.sampleRate
            timeline.append(gain: g, frameTime: t)

            near.framesEmitted += 1
            near.pending.removeFirst(Self.hopSize)
        }
    }

    // MARK: - Spectrum

    /// Per-band energy (sum of |X|²) for one 512-sample frame.
    func bandEnergies(_ frame: [Float]) -> [Float] {
        guard let fftSetup, frame.count == Self.frameSize else {
            return [Float](repeating: 0, count: Self.bandCount)
        }
        frame.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, hann, 1, windowed, 1, vDSP_Length(Self.frameSize))
        }
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) { c in
            vDSP_ctoz(c, 2, &split, 1, vDSP_Length(Self.bins))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
        // zrip packs Nyquist into imagp[0]; zero it so the DC band stays clean.
        imagp[0] = 0
        vDSP_zvmags(&split, 1, mags, 1, vDSP_Length(Self.bins))

        var out = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let (lo, hi) = bandBinRanges[b]
            var sum: Float = 0
            vDSP_sve(mags + lo, 1, &sum, vDSP_Length(hi - lo))
            out[b] = sum
        }
        return out
    }

    // MARK: - Delay estimation

    /// Frame offset between the two streams' numbering (near frame n lines up
    /// in wall-clock time with far frame n + offset). Both stamp from the same
    /// SessionClock, so this is exact — only the *acoustic* lag is unknown.
    private var frameOffset: Int? {
        guard let nt = near.t0, let ft = far.t0 else { return nil }
        return Int((((nt - ft) * Self.sampleRate) / Double(Self.hopSize)).rounded())
    }

    private func estimateDelay() {
        guard let offset = frameOffset, nearNewest >= 0, farNewest >= 0 else { return }
        let nearEnd = nearNewest
        // The window must start late enough that EVERY candidate lag has a far
        // frame available. Otherwise the largest lags reference negative far
        // indices, get discarded, and only lag 0 survives — which silently
        // returns a garbage near-zero correlation until the stream has scrolled
        // past the whole search range.
        let minStart = max(0, Self.maxLagFrames - offset)
        var nearStart = nearEnd - min(Self.corrWindowFrames, nearEnd + 1) + 1
        if nearStart < minStart { nearStart = minStart }
        let count = nearEnd - nearStart + 1
        guard count >= Self.corrMinFrames else { return }
        guard nearStart > nearNewest - Self.historyFrames + Self.maxLagFrames else { return }

        var a = [Float](repeating: 0, count: count)
        for i in 0..<count {
            a[i] = nearLog[wrap(nearStart + i)]
        }
        let (aMean, aVar) = meanVar(a)
        guard aVar > 1e-6 else { return }

        // Require the far channel to actually be active over the window,
        // otherwise there is nothing to correlate against.
        var activeFrames = 0
        for i in 0..<count {
            let m = nearStart + i + offset
            if m >= 0, m <= farNewest, m > farNewest - Self.historyFrames,
               farLog[wrap(m)] > log(Self.energyFloor) {
                activeFrames += 1
            }
        }
        let activeFrac = Float(activeFrames) / Float(count)

        // How much of the window the double-talk detector flagged — decides
        // whether a failed correlation is evidence (path gone) or just
        // contamination (user talking), and whether an accepted one exposes a
        // false latch. Normalized to FAR-ACTIVE frames: the flag is only
        // defined while the far end plays, and its natural speech pauses
        // clear it, so a whole-window fraction could never reach the
        // false-latch threshold no matter how stuck the detector was.
        var dtFrames = 0
        for i in 0..<count where doubleTalkHistory[wrap(nearStart + i)] { dtFrames += 1 }
        let dtFrac = activeFrames > 0 ? Float(dtFrames) / Float(activeFrames) : 0

        if Self.debugEstimates { log("echo est: frame=\(nearNewest) count=\(count) farActive=\(activeFrac) dtFrac=\(dtFrac)") }
        guard activeFrac >= 0.3 else {
            if Self.debugEstimates { log("echo est: rejected — far end inactive") }
            // No far audio ⇒ no echo risk and no evidence about the acoustic
            // path either way. Decaying here disengaged a locked suppressor
            // during long near-end turns, so the far end's next reply opened
            // at unity gain and leaked into the transcript.
            if !engagedValue { decayConfidence() }
            return
        }

        var best: (lag: Int, r: Float) = (0, -1)
        var scores = [Float](repeating: -1, count: Self.maxLagFrames + 1)
        for d in 0...Self.maxLagFrames {
            var b = [Float](repeating: 0, count: count)
            var ok = true
            for i in 0..<count {
                let m = nearStart + i + offset - d
                guard m >= 0, m <= farNewest, m > farNewest - Self.historyFrames else { ok = false; break }
                b[i] = farLog[wrap(m)]
            }
            guard ok else { continue }
            let (bMean, bVar) = meanVar(b)
            guard bVar > 1e-6 else { continue }
            var cov: Float = 0
            for i in 0..<count { cov += (a[i] - aMean) * (b[i] - bMean) }
            let r = cov / (Float(count) * sqrt(aVar) * sqrt(bVar))
            scores[d] = r
            if r > best.r { best = (d, r) }
        }

        if Self.debugEstimates { log("echo est: best lag=\(best.lag) r=\(best.r)") }
        guard best.r >= Self.corrAcceptThreshold else {
            if Self.debugEstimates { log("echo est: rejected — correlation below threshold") }
            rejectEstimate(dtFrac: dtFrac)
            return
        }
        // Prominence: the peak must stand out from the rest of the search
        // range, rejecting the broad flat correlation unrelated signals give.
        // An *additive* margin, not a ratio: speech envelopes have quasi-
        // periodic structure, so secondary peaks are legitimately high and a
        // ratio test would reject the true lag.
        var runnerUp: Float = -1
        for d in 0...Self.maxLagFrames where abs(d - best.lag) > 2 {
            runnerUp = max(runnerUp, scores[d])
        }
        guard runnerUp < 0 || best.r >= runnerUp + Self.corrProminence else {
            if Self.debugEstimates { log("echo est: rejected — peak not prominent (runnerUp=\(runnerUp))") }
            rejectEstimate(dtFrac: dtFrac)
            return
        }

        let previousLag = lagFrames
        recentLags.append(best.lag)
        if recentLags.count > 5 { recentLags.removeFirst() }
        lagFrames = recentLags.sorted()[recentLags.count / 2]   // median — kills outliers

        // Sub-frame refinement: the true acoustic lag is almost never a whole
        // number of 16 ms frames, and quantizing it misaligns the reference
        // window enough to blunt suppression at burst onsets. Parabolic
        // interpolation of the correlation peak recovers the fraction, which
        // `gainForNearFrame` uses to blend adjacent far frames.
        var fractional = Float(lagFrames)
        if lagFrames > 0, lagFrames < Self.maxLagFrames {
            let rm = scores[lagFrames - 1], r0 = scores[lagFrames], rp = scores[lagFrames + 1]
            if rm > -1, rp > -1 {
                let denom = rm - 2 * r0 + rp
                if abs(denom) > 1e-6 {
                    let delta = 0.5 * (rm - rp) / denom
                    if abs(delta) <= 1 { fractional = Float(lagFrames) + delta }
                }
            }
        }
        lagFractional = fractional

        // Seed on the first accepted estimate rather than easing up from zero:
        // an EMA from 0 needs two accepted estimates to cross the threshold,
        // which costs an extra second of un-suppressed echo at session start.
        // A peak that already cleared the accept threshold and the prominence
        // margin is trustworthy on its own.
        confidenceValue = confidenceValue == 0 ? best.r : confidenceValue * 0.5 + best.r * 0.5
        engagedValue = confidenceValue >= Self.engageThreshold

        // False double-talk latch: the window correlates at the lag we were
        // already locked to, yet the detector called ~all of it double-talk.
        // Real near speech would have broken the correlation, so this is echo
        // the frozen coupling under-predicts. Unlatch and reseed. The
        // same-lag requirement keeps a coincidental correlation during real
        // double-talk from opening the reseed window and corrupting coupling.
        if dtFrac >= Self.doubleTalkFalseLatchFraction, best.lag == previousLag {
            doubleTalkEnergyRatio = 1
            couplingReseedRemaining = Self.couplingReseedFrames
            if Self.debugEstimates { log("echo est: false double-talk latch — reseeding coupling") }
        }
    }

    /// A rejected estimate only erodes confidence when the window was clean:
    /// far end active, near end quiet. Near-end speech decorrelates the
    /// envelopes for as long as the user talks, and treating that as "the
    /// acoustic path is gone" disengaged the suppressor mid-meeting.
    private func rejectEstimate(dtFrac: Float) {
        if !engagedValue || dtFrac < Self.doubleTalkSkipDecayFraction {
            decayConfidence()
        } else if Self.debugEstimates {
            log("echo est: rejection attributed to near-end speech — confidence kept")
        }
    }

    private func decayConfidence() {
        confidenceValue *= Self.confidenceDecayPerEstimate
        engagedValue = confidenceValue >= Self.engageThreshold
    }

    @inline(__always)
    private func wrap(_ frame: Int) -> Int {
        ((frame % Self.historyFrames) + Self.historyFrames) % Self.historyFrames
    }

    private func meanVar(_ x: [Float]) -> (Float, Float) {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var acc: Float = 0
        for v in x { acc += (v - mean) * (v - mean) }
        return (mean, acc / Float(x.count))
    }

    // MARK: - Gain

    private func gainForNearFrame(index n: Int, bands nearBands: [Float]) -> Float {
        // Overwritten below once double-talk is actually computed; the early
        // returns leave it false so un-analyzed frames read as clean.
        doubleTalkHistory[wrap(n)] = false

        // Not engaged → bit-identical passthrough. This is the headphone case
        // and the safety default; never merely "close to" unity.
        guard engagedValue, let offset = frameOffset else {
            smoothedGain = 1.0
            return 1.0
        }
        // Blend the two far frames the fractional lag falls between.
        let d0 = Int(lagFractional.rounded(.down))
        let frac = lagFractional - Float(d0)
        let mHi = n + offset - d0          // nearer in time
        let mLo = mHi - 1                  // one frame further back
        func valid(_ m: Int) -> Bool { m >= 0 && m <= farNewest && m > farNewest - Self.historyFrames }
        guard valid(mHi), valid(mLo) else {
            smoothedGain = 1.0
            return 1.0
        }
        let slotHi = wrap(mHi), slotLo = wrap(mLo)

        var totalNear: Float = 0
        var totalEcho: Float = 0
        var totalFar: Float = 0
        var farBandsNow = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f = (1 - frac) * farBands[slotHi * Self.bandCount + b]
                  + frac * farBands[slotLo * Self.bandCount + b]
            farBandsNow[b] = f
            totalNear += nearBands[b]
            totalFar += f
            totalEcho += coupling[b] * f
        }

        // Is the far end actually playing? Tracked as a decaying peak so the
        // test is scale-free (FFT energies are unnormalized).
        farPeak = max(farPeak * Self.farPeakDecay, totalFar)
        let farActive = totalFar > farPeak * Self.farActiveFraction

        // Double-talk: near energy well above the *predicted echo* means the
        // user is speaking over the far end. Freeze coupling and raise the
        // floor so their voice survives.
        //
        // Only meaningful while the far end is active: during a far-end pause
        // there is no echo to confuse, and totalEcho → 0 would otherwise make
        // the ratio explode and spuriously latch double-talk on every pause.
        if farActive {
            let ratio = totalNear / max(totalEcho, Self.eps)
            doubleTalkEnergyRatio = doubleTalkEnergyRatio * 0.5 + ratio * 0.5  // ≈100 ms
        } else {
            doubleTalkEnergyRatio = doubleTalkEnergyRatio * 0.5 + 1.0 * 0.5
        }
        let doubleTalk = farActive && doubleTalkEnergyRatio > Self.doubleTalkRatio
        doubleTalkHistory[wrap(n)] = doubleTalk

        // Coupling adapts only on far-only frames, so a mid-meeting volume
        // change is tracked but near-end speech never corrupts the estimate.
        // The reseed window (opened only on correlation-verified false
        // latches) is the one exception: there the "double-talk" is known to
        // be echo, so both the freeze and the 4× outlier gate must yield or
        // coupling could never catch up to a large jump.
        let reseeding = couplingReseedRemaining > 0
        if reseeding { couplingReseedRemaining -= 1 }
        if !doubleTalk || reseeding {
            for b in 0..<Self.bandCount {
                let f = farBandsNow[b]
                guard f > Self.energyFloor else { continue }
                guard reseeding || nearBands[b] < 4 * coupling[b] * f else { continue }
                let observed = nearBands[b] / f
                coupling[b] += Self.couplingStep * (observed - coupling[b])
                coupling[b] = min(max(coupling[b], Self.couplingMin), Self.couplingMax)
            }
        }

        // Per-band Wiener-style gain, collapsed to a scalar by energy weight.
        var weighted: Float = 0
        var weight: Float = 0
        for b in 0..<Self.bandCount {
            let en = nearBands[b]
            guard en > Self.eps else { continue }
            let echo = coupling[b] * farBandsNow[b]
            let residual = max(0, en - Self.overSubtraction * echo)
            let gb2 = residual / max(en, Self.eps)     // already squared (energy domain)
            weighted += gb2 * en
            weight += en
        }
        let raw = weight > Self.eps ? sqrt(weighted / weight) : 1.0
        let floor = doubleTalk ? Self.gainFloorDoubleTalk : Self.gainFloor
        let target = min(1.0, max(floor, raw))

        if doubleTalk {
            // Safety-critical direction: the user is speaking, so un-suppress
            // IMMEDIATELY rather than easing up over the release constant.
            // Clipping the start of their sentence is the one failure we
            // refuse; letting a little echo through is acceptable.
            smoothedGain = max(smoothedGain, target)
        } else {
            let alpha = target < smoothedGain ? Self.alphaAttack : Self.alphaRelease
            smoothedGain = alpha * smoothedGain + (1 - alpha) * target
        }
        return min(1.0, max(floor, smoothedGain))
    }
}
