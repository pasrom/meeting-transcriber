@testable import MeetingTranscriber
import XCTest

/// The decision a caller makes after observing one load attempt, its own or one it
/// joined (issue #738). Tested here rather than through the engine because the case
/// that shapes the rule cannot be placed by a test: it needs the variant to change
/// away and back inside the window between a flight ending and its caller resuming.
final class LoadAttemptTests: XCTestCase {
    private let current = "openai_whisper-small"

    func testALoadedPipeNeedsNothingFurther() {
        let attempt = LoadAttempt(variant: current, builtPipe: true)

        XCTAssertFalse(attempt.needsAnotherAttempt(pipeInstalled: true, requestedVariant: current))
    }

    /// The load-bearing case. The attempt built a pipe and the reconcile dropped it
    /// because the variant had moved on. By the time the caller looks, the variant has
    /// moved back, so the names match again and only `builtPipe` distinguishes this
    /// from a plain failure. Reading it as a failure is the original bug: nothing
    /// loaded, and `ensureModel` throws.
    func testADiscardedPipeIsRetriedEvenWhenTheVariantMatchesAgain() {
        let attempt = LoadAttempt(variant: current, builtPipe: true)

        XCTAssertTrue(
            attempt.needsAnotherAttempt(pipeInstalled: false, requestedVariant: current),
            "An attempt that built a pipe which is now gone was superseded, not failed",
        )
    }

    /// The guard against retrying what will fail again: an offline load that failed
    /// for the variant still requested must not be repeated, for this caller or for
    /// any that joined it.
    func testAFailureForTheCurrentVariantIsNotRetried() {
        let attempt = LoadAttempt(variant: current, builtPipe: false)

        XCTAssertFalse(
            attempt.needsAnotherAttempt(pipeInstalled: false, requestedVariant: current),
            "Repeating this would double the wait and the failed download for every caller",
        )
    }

    /// A failure for a variant nobody wants any more still leaves the current one
    /// untried, so it has to be tried.
    func testAFailureForASupersededVariantIsRetried() {
        let attempt = LoadAttempt(variant: "openai_whisper-tiny", builtPipe: false)

        XCTAssertTrue(
            attempt.needsAnotherAttempt(pipeInstalled: false, requestedVariant: current),
            "The variant that is actually requested has not been attempted yet",
        )
    }
}
