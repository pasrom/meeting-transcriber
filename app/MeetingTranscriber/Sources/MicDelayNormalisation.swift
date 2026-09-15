import Foundation

/// Turns a microphone that started *before* the app tap back into the alignment
/// every consumer downstream already understands.
///
/// `AudioCaptureResult.micDelay` is mic-minus-app, so opening the microphone
/// first, which is the repair for issue #693, makes it negative on every
/// dual-source recording. The sign itself is handled nearly everywhere. What is
/// not handled is the timeline disagreement it exposes: `AudioMixer.mix` answers
/// a negative delay by prepending zeros to the *app* track, so the mix begins at
/// the microphone's first frame, while `mergeDualSourceSegments` and
/// `DiarizationProcess.shiftSegments` put the transcript and the diarization on
/// the *app's*. The speaker-naming dialog plays snippets out of the persisted
/// mix indexed by diarization times, so those two disagreeing is not an
/// abstraction, it is every snippet arriving early.
///
/// Rather than teach a dozen consumers a new sign, the app track is padded once,
/// on disk, and the reported delay becomes zero. Afterwards the app track, the
/// microphone track, the mix, the transcript and the diarization all share one
/// origin, and a fleet consumer that never reads the sidecar gets correct
/// alignment for free. The prepended silence is truthful rather than synthetic:
/// the tap genuinely was not running for that stretch, and the same track
/// already receives silence for restart gaps through `TimelineAnchor`.
///
/// The measured delta is not lost. It stays signed on `AudioCaptureResult`, and
/// the recorder logs both values.
enum MicDelayNormalisation {
    struct Decision: Equatable {
        /// Frames of silence to prepend to the 16 kHz app track. Zero leaves the
        /// track exactly as it was.
        let padFrames: Int
        /// The delay to hand to the mixer and to report in `RecordingResult`.
        /// Zero once padded, because the files then need no further shift.
        let reportedDelay: TimeInterval
    }

    static func decide(rawDelay: TimeInterval, micLoaded: Bool, sampleRate: Int) -> Decision {
        // Strictly negative. Crash recovery and every single-source path build
        // with a literal zero, and "not positive" would grow a pad out of them.
        //
        // `micLoaded` is load-bearing rather than defensive: with no microphone
        // file the app samples go into an app-only mix, and padding them there
        // would prepend silence to a recording with no second track to align to.
        guard rawDelay < 0, micLoaded, sampleRate > 0 else {
            return Decision(padFrames: 0, reportedDelay: rawDelay)
        }
        // One clamp, the mixer's. It bounds a first-frame timestamp corrupted by
        // a device switch (issue #99), and a second policy here would be a
        // second number to keep in step. A real lead beyond the clamp stays
        // under-corrected by the excess, which is the accepted limit.
        let lead = -AudioMixer.clampMicDelay(rawDelay)
        // Rounded, not truncated: the pad is asserted to within one sample.
        let frames = Int((lead * Double(sampleRate)).rounded())
        guard frames > 0 else { return Decision(padFrames: 0, reportedDelay: rawDelay) }
        return Decision(padFrames: frames, reportedDelay: 0)
    }
}
