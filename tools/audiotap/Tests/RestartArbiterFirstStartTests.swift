@testable import AudioTapLib
import XCTest

/// The first start of a microphone capture, as the arbiter sees it (issue #778).
///
/// The first engine is brought up by the same call that wedges a restart
/// (issue #588), so it runs as an attempt too: off the main queue, with a
/// generation and under `attemptTimeout`. What differs is what a failure
/// means. `start()` is still waiting for it and throws it to its caller, so a
/// first start that comes back with an error is not retried, and it leaves
/// nothing outstanding behind it.
final class RestartArbiterFirstStartTests: XCTestCase {
    func testAFirstStartIsLaunchedAsAnAttempt() {
        var arbiter = RestartArbiter()
        XCTAssertEqual(arbiter.handle(.firstStartRequested), .launchAttempt(generation: 1))
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 1))
        XCTAssertFalse(arbiter.isCapturing, "no buffer may be written before the start is adopted")
        XCTAssertTrue(arbiter.mayCreateOutputFile, "the first start creates the recording's file")
    }

    func testASuccessfulFirstStartIsAdoptedIntoCapturing() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.firstStartRequested)
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: true)), .commit)
        XCTAssertEqual(arbiter.handle(.commitReady(generation: 1)), .adopt)
        XCTAssertEqual(arbiter.phase, .capturing)
    }

    /// The caller is told and owns what is left; a backoff here would be a
    /// retry nobody schedules, and a phase that claims one is outstanding.
    func testAFailedFirstStartReturnsToIdleWithoutARetry() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.firstStartRequested)
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: false)), .startFailed)
        XCTAssertEqual(arbiter.phase, .idle)
        XCTAssertEqual(arbiter.handle(.stopRequested), .teardown, "nothing holds the engine after a returned failure")
    }

    /// The case the deadline exists for: terminal, and the session stays
    /// sealed against the wedged call returning later.
    func testAFirstStartThatNeverReturnsGivesUp() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.firstStartRequested)
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 1)), .giveUp)
        XCTAssertEqual(arbiter.phase, .gaveUp)
        XCTAssertFalse(arbiter.mayCreateOutputFile, "a late return must not create the recording's file")
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: true)), .rejectStale)
        XCTAssertEqual(arbiter.handle(.stopRequested), .sealAndSkipEngine, "the wedged call may hold the engine")
    }

    /// The deadline and the return can cross: the attempt reports back just
    /// before the waiting thread acts on its timeout. The return wins.
    func testATimeoutAfterTheFirstStartReturnedIsIgnored() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.firstStartRequested)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 1)), .ignore)
        XCTAssertEqual(arbiter.handle(.commitReady(generation: 1)), .adopt)
    }

    /// Being a first start must end at the adoption, or the first restart
    /// that fails after it would be treated as a failed first start and
    /// dropped instead of retried.
    func testARestartAfterAnAdoptedFirstStartStillRetries() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.firstStartRequested)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        _ = arbiter.handle(.commitReady(generation: 1))
        XCTAssertEqual(arbiter.handle(.deviceChanged), .launchAttempt(generation: 2))
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 2, succeeded: false)), .retry)
        XCTAssertEqual(arbiter.phase, .backingOff)
    }

    func testASecondFirstStartIsIgnored() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.firstStartRequested)
        XCTAssertEqual(arbiter.handle(.firstStartRequested), .ignore)
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 1))
    }
}
