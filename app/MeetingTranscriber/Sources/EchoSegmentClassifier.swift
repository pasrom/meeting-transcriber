import Foundation

/// What one microphone segment turned out to be.
enum EchoSegmentVerdict: Equatable {
    /// Everything audible in the segment is explained by the app track: the
    /// loudspeaker coming back through the microphone. Safe to drop from the
    /// transcript, because a copy of it is already there from the other track.
    case echoOnly
    /// Carries energy the app track cannot account for, on top of the copy.
    /// Someone spoke over the far end, so the segment has to stay.
    case mixed
    /// Nothing here came from the loudspeaker.
    case ownVoice
    /// No honest answer: nothing audible, or outside the recording.
    case undecided
}

/// Decides, per microphone segment, whether it is the loudspeaker coming back.
///
/// **Why this is an audio question and not a text question.** The tempting
/// implementation compares the two transcripts and drops microphone lines that
/// read like an app line nearby. Measured on a real call, that deletes the
/// user's own sentence: a far end replaying what you just said produces exactly
/// the same pair of lines as a loudspeaker bleeding into your microphone. Only
/// the acoustics tell them apart, so the text never gets a vote here.
///
/// **How.** The loudspeaker path is linear and slow-moving: what the microphone
/// picks up from it is the app track, delayed and attenuated by one gain. Fit
/// that gain, predict the microphone envelope from the app envelope, and look at
/// what is left over. A segment the prediction accounts for is a copy. A segment
/// with energy above the prediction has someone talking in it.
///
/// Deliberately not a correlation: correlation says "these rise and fall
/// together", which is also true of a segment where the local speaker talks
/// *while* the far end does. The residual is what separates those, and that
/// separation is the entire point, because dropping a segment that contains
/// local speech is the one mistake this must never make.
///
/// **And it does make it, under the alignment production uses.** That "must
/// never" is the intent, not the measured behaviour. Threading the detector's
/// own measured lag in, which is the only way production ever calls this, fits
/// the prediction well enough to explain a local speaker at 0.6 of the bleed,
/// and the segment is removed with that person's words in it. Pinned by
/// `EchoSegmentClassifierTests.testSoftLocalSpeakerIsDeletedUnderProductionAlignment`,
/// marked as an expected failure so the suite turns red the day it stops being
/// true.
///
/// Tightening `echoResidualCeiling` does not repair it. A true copy arriving
/// through anything a real room adds (a reflection, a volume ride, a stepped
/// gain control) leaves more unexplained energy behind than a soft interjector
/// does, so lowering the ceiling stops removing real copies before it starts
/// protecting a soft speaker. The remedy the project took is a layer up,
/// `EchoRemedy` giving `.cancellation` precedence. That protects only someone
/// who turned cancellation on, which is off by default as well: with the dedup
/// alone nothing here defends the local speaker, and that is the standing
/// reason `AppSettings.echoDedupEnabled` stays off.
enum EchoSegmentClassifier {
    /// One envelope frame. Long enough to be cheap, short enough that a syllable
    /// of local speech inside an otherwise-echo segment still shows up.
    static let frameSeconds = 0.010

    /// At or below this share of unexplained energy the segment is a copy.
    static let echoResidualCeiling = 0.20
    /// At or above it, someone is talking who is not on the app track.
    static let ownVoiceResidualFloor = 0.45

    /// Floors are relative to each track's own speech level rather than fixed
    /// dBFS: capture chains differ in gain by far more than the margin any
    /// absolute threshold would have.
    private static let speechPercentile = 0.90
    private static let activityFraction = 0.10

    /// Longest segment that may be called a copy. A verdict pools amplitude
    /// over the whole segment, so the longer it is, the smaller the share a
    /// local utterance inside it contributes and the more certainly it is
    /// averaged away. Past this length the number stops being a statement about
    /// the segment.
    ///
    /// Anchored on the detector's own minimum evidence span rather than picked:
    /// a segment longer than everything the detector needs to reach a verdict at
    /// all cannot be localised by one pooled residual.
    ///
    /// This is not a theoretical bound. `ParakeetEngine.transcribeSegments`
    /// emits a SINGLE segment spanning the entire recording when the model
    /// returns no per-token timings, and removing that would delete everything
    /// the local person said for the whole meeting.
    static let maxRemovableSegmentSeconds =
        EchoBleedDetector.windowSeconds * Double(EchoBleedDetector.minScoredWindows)

    /// Where in the sorted per-block mic/app ratios the gain is read. Low,
    /// because local speech only ever pushes ratios up; high enough that the
    /// occasional under-shooting block (envelope jitter, segment edges) does
    /// not set the gain from noise.
    private static let gainQuantile = 0.2
    /// Ratios are taken over blocks of this many frames rather than single
    /// frames. The alignment is whole frames, but the acoustic path adds a
    /// sub-frame remainder that makes single-frame ratios scatter around the
    /// true gain — and a low quantile would then read the scatter's floor,
    /// not the gain. A block absorbs the remainder while staying shorter
    /// than a syllable pause, so blocks where the echo is alone stay clean.
    private static let gainBlockFrames = 5

    /// `windowScores` is the detector's own per-window measurement of where
    /// the two tracks actually match. When present it carries the acoustic
    /// path delay (a Bluetooth loudspeaker adds 100–200 ms) that `micDelay`
    /// alone cannot know — `micDelay` only says when the files started, not
    /// how long the sound took to travel. Empty means nobody measured, and
    /// the alignment falls back to `micDelay`.
    static func classify(
        app: [Float],
        mic: [Float],
        sampleRate: Int,
        micDelay: TimeInterval,
        micSegments: [TimestampedSegment],
        windowScores: [EchoBleedDetector.WindowScore] = [],
    ) -> [EchoSegmentVerdict] {
        // One verdict per segment, always. A shorter array would still be safe
        // at today's only call site, which ignores a count that does not match,
        // but it is a contract a later caller would reasonably index into.
        guard !micSegments.isEmpty else { return [] }
        let framesPerSecond = 1.0 / frameSeconds
        let samplesPerFrame = Int(frameSeconds * Double(sampleRate))
        guard sampleRate > 0, samplesPerFrame > 0 else { return micSegments.map { _ in .undecided } }

        let appEnvelope = envelope(app, samplesPerFrame)
        let micEnvelope = envelope(mic, samplesPerFrame)
        guard !appEnvelope.isEmpty, !micEnvelope.isEmpty else {
            return micSegments.map { _ in .undecided }
        }

        // The microphone file is missing its first `micDelay` seconds when the
        // mic started late, so microphone frame `i` lines up with app frame
        // `i + offset`. This is the same convention the detector encodes from
        // the other side (it centres its lag search at `-micDelay` because it
        // pairs `app[k]` with `mic[k + lag]`), and the same one `AudioMixer.mix`
        // and `mergeDualSourceSegments` use. Getting the sign backwards here is
        // invisible: the prediction stops matching, every segment reads as local
        // speech, and nothing is ever dropped.
        let offset = Int((alignment(micDelay: micDelay, windowScores: windowScores) * framesPerSecond).rounded())

        let path = FittedPath(
            appEnvelope: appEnvelope,
            micEnvelope: micEnvelope,
            offset: offset,
            micFloor: speechFloor(micEnvelope),
            gain: estimateGain(appEnvelope, micEnvelope, offset: offset, floor: speechFloor(appEnvelope)),
            framesPerSecond: framesPerSecond,
        )
        return micSegments.map(path.verdict(for:))
    }

    // MARK: - The fitted acoustic path

    /// The loudspeaker-to-microphone path, once fitted: one gain, one offset,
    /// and the two envelopes it relates. A value rather than five arguments
    /// threaded through a helper, because asking it about a segment is the only
    /// thing anyone does with it.
    private struct FittedPath {
        let appEnvelope: [Double]
        let micEnvelope: [Double]
        let offset: Int
        let micFloor: Double
        let gain: Double
        let framesPerSecond: Double

        /// What the loudspeaker alone would put in microphone frame `frame`.
        func predicted(_ frame: Int) -> Double {
            let index = frame + offset
            guard index >= 0, index < appEnvelope.count else { return 0 }
            return gain * appEnvelope[index]
        }

        func verdict(for segment: TimestampedSegment) -> EchoSegmentVerdict {
            let first = max(0, Int(segment.start * framesPerSecond))
            let last = min(micEnvelope.count, Int(segment.end * framesPerSecond))
            guard last > first else { return .undecided }

            var micEnergy = 0.0
            var explained = 0.0
            for frame in first ..< last {
                micEnergy += micEnvelope[frame]
                // Capped at what is actually there: an overestimated gain must
                // not let the prediction "explain" more energy than the
                // microphone recorded and drive the residual negative.
                explained += min(micEnvelope[frame], predicted(frame))
            }
            guard micEnergy / Double(last - first) > micFloor else { return .undecided }

            let residual = (micEnergy - explained) / micEnergy
            if residual <= echoResidualCeiling {
                // Explained, but only removable if the segment is short enough
                // for that to mean something. Reported as mixed rather than
                // undecided: the far end demonstrably IS in here, we just
                // cannot say it is all that is.
                return segment.end - segment.start <= maxRemovableSegmentSeconds ? .echoOnly : .mixed
            }
            if residual >= ownVoiceResidualFloor { return .ownVoice }
            return .mixed
        }
    }

    /// The mic-to-app alignment in seconds, preferring what was measured over
    /// what was configured. The detector's affected windows peaked where the
    /// bleed actually sits, which is the file-start offset plus the acoustic
    /// path — a Bluetooth speaker's 100–200 ms would otherwise misalign every
    /// prediction and silently no-op the whole dedup. The median over the hot
    /// windows, because bleed travels one path and a lone outlier window must
    /// not steer the alignment. Negated: the detector pairs `app[k]` with
    /// `mic[k + lag]` while this pairs `mic[i]` with `app[i + offset]`, so the
    /// two conventions are mirror images. Cold windows are ignored — their
    /// peak lag is wherever a coincidence put it.
    static func alignment(
        micDelay: TimeInterval, windowScores: [EchoBleedDetector.WindowScore],
    ) -> TimeInterval {
        let hotLags = windowScores
            .filter { $0.correlation > EchoBleedDetector.correlationThreshold }
            .map(\.lagSeconds)
            .sorted()
        guard !hotLags.isEmpty else { return AudioMixer.clampMicDelay(micDelay) }
        return -hotLags[hotLags.count / 2]
    }

    private static func envelope(_ samples: [Float], _ samplesPerFrame: Int) -> [Double] {
        let frames = samples.count / samplesPerFrame
        guard frames > 0 else { return [] }
        return (0 ..< frames).map { frame in
            var acc = 0.0
            for i in (frame * samplesPerFrame) ..< ((frame + 1) * samplesPerFrame) {
                acc += Double(samples[i]) * Double(samples[i])
            }
            return (acc / Double(samplesPerFrame)).squareRoot()
        }
    }

    /// A tenth of this track's own speech level. Anything quieter is room tone
    /// as far as this decision is concerned.
    private static func speechFloor(_ envelope: [Double]) -> Double {
        let sorted = envelope.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * speechPercentile))
        return sorted[index] * activityFraction
    }

    /// The loudspeaker-to-microphone gain, read as a low quantile of the
    /// blockwise mic/app envelope ratios over the stretches where the far end
    /// is actually playing. One gain for the recording: the path is a room,
    /// and a room does not change between sentences.
    ///
    /// Not a least-squares fit, and the reason is one-sided: local speech
    /// only ever ADDS energy on top of the copy, so every double-talk frame
    /// pushes an averaging fit upward, never down. An inflated gain lets the
    /// prediction "explain" a soft local speaker and read a mixed segment as
    /// a copy — the one deletion this must never make, and it hits exactly
    /// the participant least able to talk over the far end. The blocks where
    /// the echo is alone sit at the true gain, and no amount of talking over
    /// the other blocks can push a low quantile off them. When the local side
    /// truly never pauses the estimate still errs high, but no further than
    /// the fit it replaces.
    ///
    /// Zero when the app track never plays, which makes every prediction zero and
    /// every audible segment local speech. That is not a fallback, it is the
    /// right answer: nothing was played, so nothing can have bled.
    private static func estimateGain(
        _ appEnvelope: [Double], _ micEnvelope: [Double], offset: Int, floor: Double,
    ) -> Double {
        var ratios: [(ratio: Double, weight: Double)] = []
        for blockStart in stride(from: 0, to: micEnvelope.count, by: gainBlockFrames) {
            var appSum = 0.0
            var micSum = 0.0
            var counted = 0
            for frame in blockStart ..< min(blockStart + gainBlockFrames, micEnvelope.count) {
                let index = frame + offset
                guard index >= 0, index < appEnvelope.count else { continue }
                appSum += appEnvelope[index]
                micSum += micEnvelope[frame]
                counted += 1
            }
            // The same activity floor as elsewhere, scaled to the block: a
            // block the far end barely reaches carries a ratio of noise.
            guard counted > 0, appSum > floor * Double(counted) else { continue }
            ratios.append((ratio: micSum / appSum, weight: appSum))
        }
        guard !ratios.isEmpty else { return 0 }
        // Quantile by app energy, not by block count. Blocks on an envelope
        // ramp under-read the ratio (the acoustic remainder of the delay
        // dominates when the far end is barely audible), and counting them
        // like full blocks would hand the quantile to the ramps. Weighting by
        // how much the far end actually played keeps the estimate with the
        // evidence.
        ratios.sort { $0.ratio < $1.ratio }
        let target = ratios.reduce(0) { $0 + $1.weight } * gainQuantile
        var cumulative = 0.0
        for entry in ratios {
            cumulative += entry.weight
            if cumulative >= target { return entry.ratio }
        }
        return ratios[ratios.count - 1].ratio
    }
}
