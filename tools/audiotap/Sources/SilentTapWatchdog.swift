import Foundation

/// Detects a process tap that is alive but capturing essentially nothing: a
/// window of buffers that is almost entirely exact digital zeros.
///
/// **This is the primary detector, not a backstop.** Nothing decides in advance
/// that an output device cannot carry audio — an earlier design tried that,
/// keyed on device transport, and broke working recordings, because transport
/// cannot tell a live virtual device from a dead one (see
/// `OutputDeviceAnchorPolicy`). The tap therefore always anchors to the system
/// default first and this type is the only evidence that ever moves it. A trip
/// advances `AnchorSearch` to the next candidate; without a trip, nothing moves.
///
/// This is a conservative heuristic, not proof of a routing failure. A far end
/// that renders digital zeros for long enough can trip it too; the window,
/// episode latch, and trigger budget bound that exposure.
///
/// **Why a fraction and not an unbroken run.** The first version of this type
/// required 120 seconds of *uninterrupted* zeros, and it never fired on a real
/// dead tap. In a 44.7-minute call whose app track was 98% silence, 55 of its
/// 530 five-second RMS windows were not -120 dBFS, scattered throughout — every
/// one of them resetting the run. A dead tap is not perfectly zero, so a
/// criterion that any single stray sample can reset is not a criterion at all.
///
/// The fraction separates the two populations cleanly. Maximum share of exactly
/// zero samples in any rolling 120-second window, measured across a whole
/// library:
///
///     healthy recordings (20 files):   12.2% ... 41.7%
///     dead recordings     (6 files):   98.7% ... 100%
///
/// Nothing lands between 41.7% and 98.7%. `defaultZeroFractionThreshold` sits
/// in that empty gap rather than being tuned against either edge.
///
/// **Why the window stays at 120 seconds.** A shorter window is *not* made safe
/// by the fractional criterion; it is made dangerous by it. The healthy ceiling
/// is essentially the longest idle stretch divided by the window: the longest
/// unbroken zero run measured during healthy operation is 49.85 s, and
/// 49.85/120 = 41.5%, which is the observed 41.7% almost exactly. Halving the
/// window to 60 s would therefore lift the healthy ceiling to roughly 83% and
/// leave almost nothing between it and a 90% threshold. The window length is
/// what creates the separation, so it is load-bearing rather than incidental.
///
/// **Caveat on the measurement.** Both distributions were measured on the
/// written 16 kHz mono files, not on the raw pre-resample buffers this type
/// sees. The resampler and `TimelineAnchor`'s gap-filling sit between the two,
/// so the files approximate the raw stream rather than reproducing it, probably
/// erring toward overstating silence. A future revision should not treat the
/// two signals as identical.
///
/// **What counts as a zero sample.** An exactly-zero sample, or every sample of
/// a buffer whose RMS is below one 16-bit step (`zeroFloorRMS`). The second
/// half is issue #699: a tap anchored on the wrong device carried a constant
/// floor of about -98.5 dBFS for a whole call, so its raw buffers held almost
/// no exact zeros while the 16-bit file was almost all zeros. Counted exactly,
/// that track reads as live, and worse, it earns the dead anchor the
/// `AnchorDeliveryCredit` that makes the search offer it first. One 16-bit step
/// is the resolution of the files the thresholds above were measured on, so
/// this moves the raw count toward the measurement rather than away from it,
/// and the thresholds stay where the corpus put them. Per buffer rather than
/// per sample because a noise floor is not a level each sample sits under: a
/// sample threshold at the step lets a floor just below it through on its
/// peaks, where the buffer's RMS stays under it throughout.
///
/// **Why the trigger budget.** The response to a trip is a tap restart, which
/// costs a fraction of a second of audio. An unbounded watchdog would chew a
/// gap into a recording every window forever. Three trips per recording bounds
/// that cost, and after the budget is spent the condition is still *reported* —
/// it just stops being acted on.
///
/// **One restart per episode, not one per window.** `isSilent` latches until
/// real signal returns, so a restart that did not fix the problem is not
/// followed by an identical restart a window later. Repeating a fix that just
/// failed only costs more audio, and the user has already been told.
struct SilentTapWatchdog: Equatable {
    /// Span the zero fraction is measured over. See the type comment for why
    /// this is load-bearing and must not be shortened.
    static let defaultWindowSeconds: TimeInterval = 120

    /// Share of zero samples in a full window that means the tap is
    /// capturing nothing. Sits in the empty gap between a healthy ceiling of
    /// 41.7% and a dead floor of 98.7%.
    static let defaultZeroFractionThreshold: Double = 0.90

    /// Share of zero samples below which real signal counts as having
    /// returned. Deliberately far under the trip threshold: without the
    /// hysteresis a window hovering at the boundary would alternate between
    /// silent and recovered from one buffer to the next.
    static let defaultRecoveryFractionThreshold: Double = 0.50

    /// How many anchor moves one recording may spend on this. See the type
    /// comment.
    static let defaultMaxTriggers = 3

    /// Sample floor for a verdict, per second of window. A window that spans
    /// two minutes on a handful of samples is a tap that has all but stopped
    /// delivering, which the level-staleness path already handles; declaring it
    /// digitally silent here would only race that. Set two orders of magnitude
    /// below any real capture rate, so it excludes the degenerate case alone.
    static let defaultMinSamplesPerSecond: Double = 100

    /// One 16-bit step, 2^-15 (about -90.3 dBFS): a buffer whose RMS is below
    /// it counts as zero throughout. See "What counts as a zero sample" above.
    static let zeroFloorRMS: Double = 1.0 / 32768.0

    /// How many of one buffer's samples count as zero, for this type and for
    /// `AnchorDeliveryCredit`, from what the capture path's RMS loop already
    /// computes. A buffer at or above the floor keeps its exact count, so
    /// audible audio is judged exactly as before.
    ///
    /// The RMS is over the raw interleaved buffer, like the exact count. For
    /// the in-phase stereo a meeting app renders, that is the level of the mono
    /// downmix that gets written. Content that cancels in the downmix, or sits
    /// in one channel only, is judged on the raw buffer, as the exact count
    /// always was.
    static func zeroSampleCount(exactZeros: Int, samples: Int, sumOfSquares: Double) -> Int {
        guard samples > 0 else { return 0 }
        let rms = (sumOfSquares / Double(samples)).squareRoot()
        return rms < zeroFloorRMS ? samples : exactZeros
    }

    enum Action: Equatable {
        /// The window crossed the threshold. Tell the user either way.
        /// `mayRestart` says whether the trigger
        /// budget also allows moving the anchor, which is the part that costs
        /// audio; reporting and acting are separate so an exhausted budget
        /// makes the failure no quieter.
        case silenceDetected(mayRestart: Bool)
        /// Real signal returned after a reported episode.
        case recovered
    }

    let windowSeconds: TimeInterval
    let zeroFractionThreshold: Double
    let recoveryFractionThreshold: Double
    let maxTriggers: Int
    let minSamplesPerSecond: Double

    /// True from a `.silenceDetected` until signal returns. Read by the app so
    /// the menu bar and the notification path can act on it without a callback.
    private(set) var isSilent = false

    private var window: RollingZeroFraction
    private var triggersFired = 0

    init(
        windowSeconds: TimeInterval = Self.defaultWindowSeconds,
        zeroFractionThreshold: Double = Self.defaultZeroFractionThreshold,
        recoveryFractionThreshold: Double = Self.defaultRecoveryFractionThreshold,
        maxTriggers: Int = Self.defaultMaxTriggers,
        minSamplesPerSecond: Double = Self.defaultMinSamplesPerSecond,
    ) {
        self.windowSeconds = windowSeconds
        self.zeroFractionThreshold = zeroFractionThreshold
        self.recoveryFractionThreshold = recoveryFractionThreshold
        self.maxTriggers = maxTriggers
        self.minSamplesPerSecond = minSamplesPerSecond
        window = RollingZeroFraction(windowSeconds: windowSeconds)
    }

    /// Feed one captured buffer.
    ///
    /// - Parameters:
    ///   - zeroSamples: how many of that buffer's samples count as zero
    ///     (`zeroSampleCount`), counted in the capture path's RMS loop.
    ///   - samples: how many samples that buffer held.
    ///   - now: monotonic seconds. Injected rather than read here so the whole
    ///     transition table is testable without waiting out a real window.
    mutating func observe(
        zeroSamples: Int, samples: Int, now: TimeInterval,
    ) -> Action? {
        guard samples > 0 else { return nil }
        window.add(zeroSamples: zeroSamples, totalSamples: samples, now: now)
        guard let fraction = window.zeroFraction else { return nil }

        if isSilent {
            // Recovery is judged on the same rolling window, so clearing an
            // episode takes sustained audio rather than one loud buffer.
            guard fraction <= recoveryFractionThreshold else { return nil }
            isSilent = false
            return .recovered
        }

        // A fraction over a partly-filled window is not comparable to the
        // measurements that set the threshold — every recording starts at 100%
        // zeros for its first buffer.
        guard let span = window.span(now: now), span >= windowSeconds else { return nil }
        guard fraction >= zeroFractionThreshold else { return nil }
        guard Double(window.totalSamples) >= span * minSamplesPerSecond else { return nil }

        isSilent = true
        guard triggersFired < maxTriggers else { return .silenceDetected(mayRestart: false) }
        triggersFired += 1
        return .silenceDetected(mayRestart: true)
    }

    /// Drop the measurement window without touching the trigger budget or the
    /// latched `isSilent`. Called when the tap is torn down: the buffers a new
    /// tap delivers must not be pooled with the dead tap's, or the next verdict
    /// would be reached against evidence from an anchor that no longer applies.
    /// The latch deliberately survives, so a move that did not help still reads
    /// as silent until real signal proves otherwise.
    mutating func resetWindow() {
        window.reset()
    }
}
