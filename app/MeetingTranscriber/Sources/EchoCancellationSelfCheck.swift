import Foundation

/// Whether a cancellation run actually removed anything, decided from the
/// canceller's own per-window measurements.
///
/// This exists because "it removed nothing" is a real outcome of this model and
/// an invisible one. On a minority of recordings it removes essentially nothing
/// once local speech is present, for the whole file rather than just the
/// overlapping parts, while removing tens of decibels from the same echo
/// presented on its own. Nothing about such a run looks wrong from the outside:
/// it completes, it writes a full-length track, and every gate stays green.
///
/// The separation below was measured on recordings that cannot be shared, so
/// the reasoning is written out here rather than pointed at: what a reader
/// needs is why these two constants have these shapes, not a citation they
/// cannot check.
///
/// Pure, and separate from the canceller, so the threshold can be chosen from
/// data without touching the code that produces the audio. That split is the
/// same one `EchoReductionVerdict` makes for the bundle probe.
enum EchoCancellationSelfCheck {
    /// What the run achieved. Three cases and not a `Bool?`, for the same
    /// reason `EchoVerdict` is not one: *not enough evidence* is not *no*, and
    /// a caller that collapses them either warns about a recording nobody
    /// measured or stays quiet about one that failed.
    enum Effect: Equatable {
        /// The reduction cleared the threshold. The echo is gone.
        case removed
        /// The run completed and took essentially nothing off. The measured
        /// silent failure.
        case ineffective
        /// The run made the recording worse where there was no echo to remove.
        /// Its own case, because "removed almost nothing" is wrong twice over
        /// for such a run: it may have removed plenty, and what disqualified it
        /// was damage, not inaction.
        case damagedControl
        /// Too little far-end audio to say either way.
        case indeterminate
    }

    /// Windows quieter than this on the reference carry no echo to remove, so
    /// a canceller doing nothing in them is the correct outcome. They are not
    /// discarded, though: how much a run attenuates them is the control that
    /// separates removing the echo from turning the whole track down. The exact
    /// value is not delicate; moving it twenty decibels either way moved the
    /// separation by less than one, because what it excludes is windows with no
    /// far end at all rather than merely quiet ones.
    static let referenceFloorDBFS: Float = -45

    /// How much more a run has to attenuate the windows carrying echo than the
    /// windows carrying none.
    ///
    /// A difference, not a level, and that is the correction that matters here.
    /// A level answers "did the track get quieter where the far end was
    /// playing", which a run that simply halves the microphone answers just as
    /// well as one that cancels: it reports about six decibels everywhere and
    /// leaves the echo exactly as audible relative to the local voice. The
    /// difference answers "did it get quieter *there specifically*", which is
    /// the only thing that distinguishes cancellation from attenuation.
    ///
    /// Placed inside the gap the two populations left, at the least favourable
    /// echo level tested, with an order of magnitude of room on the failure
    /// side and better than a factor of two on the healthy side. Healthy runs
    /// leave the quiet windows within a fraction of a decibel of untouched,
    /// which is what gives the difference its room.
    ///
    /// Serving as both the level floor and the difference floor is deliberate
    /// but not free: it holds because the control group barely moves on a
    /// healthy run, so the two quantities are nearly equal there and were
    /// measured to separate at the same place. A model that denoised the
    /// microphone broadly would break that, and it would break it the safe
    /// way, by refusing to confirm runs that worked.
    static let minMedianReductionDb: Float = 3

    /// How far the control group may move in the wrong direction.
    ///
    /// A difference rewards anything that pushes the two groups apart, and
    /// *amplifying* the windows that carry no echo does exactly that: a run
    /// barely clearing the level test with a control group boosted twenty
    /// decibels reads as a large difference and would otherwise be confirmed.
    /// That run is not cancelling anything; it is making the recording worse
    /// in the stretches where the local speaker is alone.
    ///
    /// One-sided, and measured that way. Healthy runs attenuate the control a
    /// little, occasionally by ten decibels or so, which the difference already
    /// handles by shrinking. None of them amplified it at all: across both
    /// echo levels tested the smallest control median was a small positive
    /// number. So the floor sits just below zero, where no healthy run has
    /// ever been.
    static let minQuietBaselineDb: Float = -1

    /// Fewer scored windows than this, on either side, is not enough to judge.
    /// A verdict from a handful of windows is a coin toss reported as a fact.
    static let minScoredWindows = 10

    /// What a run achieved, from its own per-window measurements.
    ///
    /// `indeterminate` covers two cases and both are real: too little far-end
    /// audio to judge, and a far end that never stops, which leaves no quiet
    /// windows to compare against. The second is exactly the situation where
    /// broad attenuation is indistinguishable from cancellation, so it is
    /// withheld rather than waved through.
    static func effect(of report: EchoCancellationReport) -> Effect {
        // Both populations first, so a run nobody could measure is never
        // reported as one that was measured and failed. The two send the user
        // to different places: one is a fault worth chasing, the other is
        // usually a far end that never paused long enough to compare against.
        guard let active = median(report.windows.filter { $0.referenceDBFS >= referenceFloorDBFS }),
              let quiet = median(report.windows.filter { $0.referenceDBFS < referenceFloorDBFS })
        else { return .indeterminate }

        guard quiet >= minQuietBaselineDb else { return .damagedControl }
        guard active >= minMedianReductionDb else { return .ineffective }
        return active - quiet >= minMedianReductionDb ? .removed : .ineffective
    }

    /// Median reduction over these windows, or nil when there are too few of
    /// them to mean anything.
    private static func median(_ windows: [EchoCancellationWindow]) -> Float? {
        guard windows.count >= minScoredWindows else { return nil }
        let sorted = windows.map(\.reductionDb).sorted()
        return sorted[sorted.count / 2]
    }
}
