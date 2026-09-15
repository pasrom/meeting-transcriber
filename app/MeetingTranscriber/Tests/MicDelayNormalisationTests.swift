@testable import MeetingTranscriber
import XCTest

/// How a microphone that started *before* the app tap is turned back into the
/// alignment every consumer downstream already understands.
///
/// The recorder reports `micDelay` as mic-minus-app, so opening the microphone
/// first (the repair for issue #693) makes it negative on every dual-source
/// recording. The sign itself is handled nearly everywhere; what is not is the
/// timeline disagreement it exposes. `AudioMixer.mix` answers a negative delay
/// by prepending zeros to the *app* track, so the mix begins at the microphone's
/// first frame, while `mergeDualSourceSegments` puts the transcript on the
/// *app's*. The naming dialog plays snippets out of the mix indexed by
/// diarization times, so those two disagreeing is a user-visible defect.
///
/// So the app track is padded once, on disk, and the reported delay becomes
/// zero. The silence is truthful: the tap was not running for that stretch.
final class MicDelayNormalisationTests: XCTestCase {
    private let rate = 16000

    func testAPositiveDelayIsLeftExactlyAsItIs() {
        // A microphone that started late is today's case and every consumer
        // already handles it. Touching it would be a change nobody asked for.
        let decision = MicDelayNormalisation.decide(rawDelay: 0.25, micLoaded: true, sampleRate: rate)
        XCTAssertEqual(decision.padFrames, 0)
        XCTAssertEqual(decision.reportedDelay, 0.25)
    }

    func testAZeroDelayPadsNothing() {
        // Crash recovery builds with a literal zero, and so does every
        // single-source path.
        let decision = MicDelayNormalisation.decide(rawDelay: 0, micLoaded: true, sampleRate: rate)
        XCTAssertEqual(decision.padFrames, 0)
        XCTAssertEqual(decision.reportedDelay, 0)
    }

    func testANegativeDelayPadsTheAppTrackAndReportsZero() {
        let decision = MicDelayNormalisation.decide(rawDelay: -0.25, micLoaded: true, sampleRate: rate)
        XCTAssertEqual(decision.padFrames, 4000)
        XCTAssertEqual(decision.reportedDelay, 0)
    }

    func testANegativeDelayPadsNothingWhenNoMicrophoneTrackLoaded() {
        // Without a microphone file there is nothing to align to, and the app
        // samples go straight into an app-only mix. Padding them there would
        // prepend silence to a recording that has no second track to justify it.
        let decision = MicDelayNormalisation.decide(rawDelay: -0.25, micLoaded: false, sampleRate: rate)
        XCTAssertEqual(decision.padFrames, 0)
        XCTAssertEqual(decision.reportedDelay, -0.25, "and the measured value is still reported")
    }

    func testTheLeadIsClampedByTheSamePolicyTheMixerUses() {
        // One clamp, not two. `AudioMixer.clampMicDelay` bounds a first-frame
        // timestamp corrupted by a device switch (issue #99), and a second
        // policy here would be a second number to keep in step.
        let decision = MicDelayNormalisation.decide(rawDelay: -45, micLoaded: true, sampleRate: rate)
        XCTAssertEqual(decision.padFrames, 30 * rate)
        XCTAssertEqual(decision.reportedDelay, 0)
    }

    func testAFractionalSampleRoundsRatherThanTruncates() {
        // Pinned because it is otherwise decided by whichever conversion the
        // implementation happens to use, and the acceptance test asserts an
        // impulse position to within one sample.
        let decision = MicDelayNormalisation.decide(rawDelay: -0.000_1, micLoaded: true, sampleRate: rate)
        XCTAssertEqual(decision.padFrames, 2, "1.6 samples rounds to 2")
    }
}
