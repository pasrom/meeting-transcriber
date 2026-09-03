@testable import MeetingTranscriber
import XCTest

/// Which of the two echo remedies runs for one recording.
///
/// The seam's own header states they must not compose: the canceller takes the
/// far end out of the microphone audio, the dedup drops microphone transcript
/// lines that duplicate the far end. Run together, the dedup judges audio the
/// echo has already been removed from. Pinned here rather than left to an `if`
/// in the transcribe stage, because "which one runs" is the requirement the
/// first consumer had to answer.
final class EchoRemedyTests: XCTestCase {
    func testCancellationWinsWhenBothAreEnabled() {
        XCTAssertEqual(
            EchoRemedy.intended(cancellationEnabled: true, dedupEnabled: true),
            .cancellation,
            "the dedup must not judge audio the canceller already cleaned",
        )
    }

    func testDedupRunsOnlyWhenCancellationIsOff() {
        XCTAssertEqual(
            EchoRemedy.intended(cancellationEnabled: false, dedupEnabled: true),
            .transcriptDedup,
        )
    }

    func testCancellationRunsWithoutTheDedup() {
        XCTAssertEqual(
            EchoRemedy.intended(cancellationEnabled: true, dedupEnabled: false),
            .cancellation,
        )
    }

    func testNeitherRemedyIsTheDefault() {
        XCTAssertEqual(
            EchoRemedy.intended(cancellationEnabled: false, dedupEnabled: false),
            .neither,
        )
    }

    // MARK: - What the recording actually got

    /// The fallback the settings-only decision took away. Both switches on and
    /// a cancellation that did not happen meant neither remedy ran, on every
    /// affected recording, with one warning line as the only sign.
    func testAFailedCancellationHandsBackToTheDedup() {
        XCTAssertEqual(
            EchoRemedy.applied(cancellationSucceeded: false, dedupEnabled: true),
            .transcriptDedup,
            "the track is exactly as recorded, so the dedup's measure is valid again",
        )
    }

    func testASucceededCancellationStillKeepsTheDedupOut() {
        XCTAssertEqual(
            EchoRemedy.applied(cancellationSucceeded: true, dedupEnabled: true),
            .cancellation,
        )
    }

    func testNoFallbackWhenTheDedupIsOffToo() {
        XCTAssertEqual(
            EchoRemedy.applied(cancellationSucceeded: false, dedupEnabled: false),
            .neither,
        )
    }
}
