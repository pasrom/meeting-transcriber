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

    static func classify(
        app: [Float],
        mic: [Float],
        sampleRate: Int,
        micDelay: TimeInterval,
        micSegments: [TimestampedSegment],
    ) -> [EchoSegmentVerdict] {
        guard !micSegments.isEmpty, sampleRate > 0 else { return [] }
        let framesPerSecond = 1.0 / frameSeconds
        let samplesPerFrame = Int(frameSeconds * Double(sampleRate))
        guard samplesPerFrame > 0 else { return micSegments.map { _ in .undecided } }

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
        let offset = Int((AudioMixer.clampMicDelay(micDelay) * framesPerSecond).rounded())

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
            if residual <= echoResidualCeiling { return .echoOnly }
            if residual >= ownVoiceResidualFloor { return .ownVoice }
            return .mixed
        }
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

    /// Least squares fit of the loudspeaker-to-microphone gain, over the frames
    /// where the far end is actually playing. One gain for the recording: the
    /// path is a room, and a room does not change between sentences.
    ///
    /// Zero when the app track never plays, which makes every prediction zero and
    /// every audible segment local speech. That is not a fallback, it is the
    /// right answer: nothing was played, so nothing can have bled.
    private static func estimateGain(
        _ appEnvelope: [Double], _ micEnvelope: [Double], offset: Int, floor: Double,
    ) -> Double {
        var numerator = 0.0
        var denominator = 0.0
        for frame in micEnvelope.indices {
            let index = frame + offset
            guard index >= 0, index < appEnvelope.count else { continue }
            let source = appEnvelope[index]
            guard source > floor else { continue }
            numerator += source * micEnvelope[frame]
            denominator += source * source
        }
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }
}
