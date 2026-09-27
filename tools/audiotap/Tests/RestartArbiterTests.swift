@testable import AudioTapLib
import XCTest

/// Transition table for `RestartArbiter`, the phase machine that bounds a single
/// capture-restart attempt (issue #588).
///
/// The invariants these pin all come from one live incident: a restart attempt
/// entered an unbounded loop inside AVFAudio and never returned, so every piece
/// of state it would have written must stay unwritable afterwards, and the
/// attempt must remain harmless if the call does eventually return (it did,
/// three hours later).
final class RestartArbiterTests: XCTestCase {
    // MARK: - The progress watchdog

    /// The watchdog rebuilds an engine that came up and never called back. It
    /// has to go through the arbiter like every other restart, or a second
    /// attempt could be launched into one that is already wedged.
    func testAnElapsedProgressDeadlineLaunchesAnAttempt() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        XCTAssertEqual(arbiter.handle(.progressDeadlineElapsed), .launchAttempt(generation: 1))
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 1))
    }

    /// An attempt is already outstanding and may be wedged inside AVFAudio, so
    /// neither watchdog event may act on it.
    func testProgressEventsDuringAnAttemptAreIgnored() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.progressDeadlineElapsed), .ignore)
        XCTAssertEqual(arbiter.handle(.progressBudgetExhausted), .ignore)
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 1))
    }

    /// A capture that went without audio for the whole budget stalls: not the
    /// terminal give-up of a wedged attempt, because its engine is idle and can
    /// be released and rebuilt.
    func testAnExhaustedBudgetStallsRatherThanGivingUp() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        XCTAssertEqual(arbiter.handle(.progressBudgetExhausted), .stall)
        XCTAssertEqual(arbiter.phase, .stalled)
        XCTAssertFalse(arbiter.isCapturing, "the tap must drop anything a released engine still hands over")
        XCTAssertEqual(arbiter.handle(.progressBudgetExhausted), .ignore, "one stall, one notification")
    }

    /// A stall keeps the recording's file, so a revived capture continues it
    /// instead of truncating it.
    func testAStallKeepsTheFileWritable() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.progressBudgetExhausted)
        XCTAssertTrue(arbiter.mayCreateOutputFile)
    }

    /// The user switches the input or reconnects the headset after being told:
    /// that brings the microphone back.
    func testADeviceChangeRevivesAStalledCapture() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.progressBudgetExhausted)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .launchAttempt(generation: 1))
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 1))
    }

    /// Nothing but a device change revives it: no watchdog timer and no retry.
    func testOnlyADeviceChangeRevivesAStalledCapture() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.progressBudgetExhausted)
        XCTAssertEqual(arbiter.handle(.progressDeadlineElapsed), .ignore)
        XCTAssertEqual(arbiter.handle(.retryDue), .ignore)
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 0)), .ignore)
        XCTAssertEqual(arbiter.phase, .stalled)
    }

    /// Its engine was already released, so a stop has nothing to tear down and
    /// says so rather than claiming an attempt is outstanding.
    func testStopAfterAStallHasNothingToRelease() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.progressBudgetExhausted)
        XCTAssertEqual(arbiter.handle(.stopRequested), .nothingToRelease)
        XCTAssertEqual(arbiter.phase, .stopped)
        XCTAssertFalse(arbiter.mayCreateOutputFile)
    }

    /// A revival whose attempts all come back with errors has not wedged
    /// anything, so it goes back to waiting for the next device change
    /// instead of ending the microphone for the rest of the recording.
    func testARevivalThatRunsOutOfRetriesReturnsToStalled() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.progressBudgetExhausted)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .launchAttempt(generation: 1))
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: false)), .retry)
        XCTAssertEqual(arbiter.handle(.retryBudgetExhausted), .returnToStall)
        XCTAssertEqual(arbiter.phase, .stalled)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .launchAttempt(generation: 2), "and can be revived again")
    }

    /// A rebuild the progress watchdog ordered is the same: its attempts all
    /// came back with errors, nothing is wedged and no device change caused
    /// it, so the capture stalls instead of ending for the recording.
    func testARebuildThatRunsOutOfRetriesStallsInsteadOfGivingUp() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        XCTAssertEqual(arbiter.handle(.progressDeadlineElapsed), .launchAttempt(generation: 1))
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: false)), .retry)
        XCTAssertEqual(arbiter.handle(.retryDue), .launchAttempt(generation: 2))
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 2, succeeded: false)), .retry)
        XCTAssertEqual(arbiter.handle(.retryBudgetExhausted), .returnToStall)
        XCTAssertEqual(arbiter.phase, .stalled)
        XCTAssertTrue(arbiter.mayCreateOutputFile, "the file stays open for a revival")
    }

    /// A revival that wedges is the #588 case like any other attempt: terminal.
    func testARevivalThatWedgesStillGivesUp() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.progressBudgetExhausted)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 1)), .giveUp)
        XCTAssertEqual(arbiter.phase, .gaveUp)
    }

    /// Once a revival was adopted the capture is an ordinary one again, and a
    /// later device-change restart that runs out of retries gives up as it
    /// always did.
    func testAfterAnAdoptedRevivalExhaustedRetriesGiveUpAsBefore() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.progressBudgetExhausted)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        XCTAssertEqual(arbiter.handle(.commitReady(generation: 1)), .adopt)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 2, succeeded: false))
        XCTAssertEqual(arbiter.handle(.retryBudgetExhausted), .giveUp)
    }

    /// A terminal give-up stays terminal: a wedged attempt may still hold the
    /// engine's mutex, and a device change must not launch into it.
    func testADeviceChangeStillCannotReviveAWedgedGiveUp() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptTimedOut(generation: 1))
        XCTAssertEqual(arbiter.handle(.deviceChanged), .ignore)
    }

    // MARK: - Launching attempts

    func testDeviceChangeWhileCapturingLaunchesFirstAttempt() {
        var arbiter = RestartArbiter()
        XCTAssertEqual(arbiter.handle(.startSucceeded), .ignore)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .launchAttempt(generation: 1))
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 1))
    }

    func testEachDeviceChangeAdvancesTheGeneration() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .launchAttempt(generation: 1))
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: true)), .commit)
        XCTAssertEqual(arbiter.handle(.commitReady(generation: 1)), .adopt)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .launchAttempt(generation: 2))
    }

    func testDeviceChangeDuringAnAttemptDoesNotLaunchASecondOne() {
        // The in-flight attempt may be wedged. Starting another one would leak a
        // second thread into the same Apple-side loop.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .ignore)
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 1))
    }

    // MARK: - Stale results

    func testLateResultFromASupersededAttemptIsRejected() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptTimedOut(generation: 1))
        // Three hours later, Apple's call finally returns.
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: true)), .rejectStale)
        XCTAssertEqual(arbiter.phase, .gaveUp)
    }

    func testLateResultIsRejectedAfterStopToo() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.stopRequested), .sealAndSkipEngine)
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: true)), .rejectStale)
        XCTAssertEqual(arbiter.phase, .stopped)
    }

    func testTimeoutForAStaleGenerationIsANoOp() {
        // The watchdog for attempt 1 fires after attempt 1 already returned and
        // attempt 2 is running. It must not kill the healthy attempt.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        _ = arbiter.handle(.commitReady(generation: 1))
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 1)), .ignore)
        XCTAssertEqual(arbiter.phase, .attemptInFlight(generation: 2))
    }

    // MARK: - Give-up is terminal

    func testTimeoutGivesUpAndNeverRetries() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 1)), .giveUp)
        XCTAssertEqual(arbiter.phase, .gaveUp)
    }

    func testGiveUpForbidsOutputFileCreationForever() {
        // The wedged attempt, if it ever returns, walks into the code that
        // recreates the WAV for writing. That truncates the finished recording.
        var arbiter = RestartArbiter()
        XCTAssertTrue(arbiter.mayCreateOutputFile)
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptTimedOut(generation: 1))
        XCTAssertFalse(arbiter.mayCreateOutputFile)
        // And nothing can talk it back into allowing it.
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.retryDue)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        XCTAssertFalse(arbiter.mayCreateOutputFile)
    }

    func testDeviceChangeAfterGiveUpIsIgnored() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptTimedOut(generation: 1))
        XCTAssertEqual(arbiter.handle(.deviceChanged), .ignore)
        XCTAssertEqual(arbiter.phase, .gaveUp)
    }

    // MARK: - Returned failures keep the existing retry path

    func testReturnedFailureAsksForARetry() {
        // A restart that FAILS is the transient case the retry budget exists for.
        // Only a restart that never returns is terminal.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: false)), .retry)
        XCTAssertEqual(arbiter.phase, .backingOff)
    }

    // MARK: - Stop

    func testStopWhileAnAttemptIsInFlightForbidsEngineAccess() {
        // stop() touches engine.inputNode and engine.stop(). The wedged attempt
        // holds the engine mutex, so touching it would wedge the caller too.
        // The action is the whole contract: callers branch on it, they do not
        // ask a separate predicate.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.stopRequested), .sealAndSkipEngine)
    }

    func testStopWhileCapturingTearsDownNormally() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        XCTAssertEqual(arbiter.handle(.stopRequested), .teardown)
        XCTAssertEqual(arbiter.phase, .stopped)
    }

    func testStopAfterGiveUpSkipsTheEngine() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptTimedOut(generation: 1))
        XCTAssertEqual(arbiter.handle(.stopRequested), .sealAndSkipEngine)
        XCTAssertEqual(arbiter.phase, .stopped)
    }

    func testStopIsIdempotent() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.stopRequested)
        XCTAssertEqual(arbiter.handle(.stopRequested), .ignore)
        XCTAssertEqual(arbiter.phase, .stopped)
    }

    // MARK: - Timeout constant

    func testAttemptTimeoutIsGenerousComparedToAHealthyRestart() {
        // A healthy restart completes in roughly 300 ms (measured in the incident
        // log). The timeout only has to catch "never returns", so it is set far
        // above that to avoid killing a slow but honest Bluetooth renegotiation.
        XCTAssertGreaterThanOrEqual(RestartArbiter.attemptTimeout, 3.0)
    }

    // MARK: - Sealing after an exhausted retry budget

    func testSealingAfterAReturnedFailureActuallySeals() {
        // The retry budget can run out on attempts that DO return. That give-up
        // has to seal the session exactly like a timeout does, or the next device
        // change relaunches into a session whose file was already closed and
        // recreates it, truncating everything recorded so far.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: false)), .retry)

        XCTAssertEqual(arbiter.handle(.retryBudgetExhausted), .giveUp)
        XCTAssertEqual(arbiter.phase, .gaveUp)
        XCTAssertFalse(arbiter.mayCreateOutputFile)
        XCTAssertEqual(arbiter.handle(.deviceChanged), .ignore)
    }

    // MARK: - The backoff window

    func testDeviceChangeDuringBackoffIsIgnored() {
        // Restoring the pacing the old isRestarting/retryScheduled flags provided:
        // a flapping device must not skip the backoff by supplying a fresh event.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: false))
        XCTAssertEqual(arbiter.handle(.deviceChanged), .ignore)
        XCTAssertEqual(arbiter.phase, .backingOff)
    }

    func testTheScheduledRetryLaunchesTheNextAttempt() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: false))
        XCTAssertEqual(arbiter.handle(.retryDue), .launchAttempt(generation: 2))
    }

    func testAWatchdogFiringDuringBackoffDoesNotGiveUp() {
        // A slow failing attempt can return just before its own deadline, so the
        // watchdog fires while the backoff is already running. Killing the track
        // there would turn a recoverable transient into a lost channel.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: false))
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 1)), .ignore)
        XCTAssertEqual(arbiter.phase, .backingOff)
    }

    func testRetryAfterAGiveUpIsIgnored() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptTimedOut(generation: 1))
        XCTAssertEqual(arbiter.handle(.retryDue), .ignore)
        XCTAssertEqual(arbiter.handle(.retryBudgetExhausted), .ignore)
    }

    func testStopDuringBackoffTearsDownNormally() {
        // Nothing is in flight, so the engine is reachable and must be released.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: false))
        XCTAssertEqual(arbiter.handle(.stopRequested), .teardown)
    }

    // MARK: - Two-phase commit

    func testSuccessIsNotCapturingUntilItIsAdopted() {
        // The attempt returns on the restart queue but publishes nothing until the
        // main queue adopts it, so stop and adoption are totally ordered.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        XCTAssertEqual(arbiter.handle(.attemptReturned(generation: 1, succeeded: true)), .commit)
        XCTAssertEqual(arbiter.phase, .committing(generation: 1))
        XCTAssertFalse(arbiter.isCapturing)
        XCTAssertEqual(arbiter.handle(.commitReady(generation: 1)), .adopt)
        XCTAssertEqual(arbiter.phase, .capturing)
    }

    func testAWatchdogFiringWhileCommittingDoesNotGiveUp() {
        // The generation still matches here, but the attempt already returned.
        // Letting the match win would kill a healthy restart.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        XCTAssertEqual(arbiter.handle(.attemptTimedOut(generation: 1)), .ignore)
        XCTAssertEqual(arbiter.phase, .committing(generation: 1))
    }

    func testAdoptionAfterAStopIsRejected() {
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        XCTAssertEqual(arbiter.handle(.stopRequested), .teardown)
        XCTAssertEqual(arbiter.handle(.commitReady(generation: 1)), .rejectStale)
    }

    func testStopWhileCommittingTearsDownRatherThanSealing() {
        // Nothing holds the engine mutex once the attempt returned, so sealing and
        // skipping here would leave a live tap running.
        var arbiter = RestartArbiter()
        _ = arbiter.handle(.startSucceeded)
        _ = arbiter.handle(.deviceChanged)
        _ = arbiter.handle(.attemptReturned(generation: 1, succeeded: true))
        XCTAssertEqual(arbiter.handle(.stopRequested), .teardown)
        XCTAssertEqual(arbiter.phase, .stopped)
    }
}
