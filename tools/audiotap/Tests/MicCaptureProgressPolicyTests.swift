@testable import AudioTapLib
import XCTest

/// Whether a microphone capture is getting anywhere.
///
/// The fault this bounds has two shapes, and each is invisible to the other's
/// test (issues #724, #706):
///
/// - A stable engine that reported `Mic recording started` and never calls
///   back. No restarts happen, so only a deadline sees it.
/// - A restart storm, about five a second, where every restart succeeds and
///   delivers nothing. Every adoption starts a new epoch, so no deadline ever
///   elapses; only the time since the last buffer grows.
///
/// And two healthy shapes it must not end: the built-in microphone's storm
/// from the same report, 78 restarts in 14 seconds and then a complete track,
/// and a Bluetooth headset whose first buffer takes a little longer than the
/// first deadline because opening the input is what flips it into its call
/// profile.
final class MicCaptureProgressPolicyTests: XCTestCase {
    private typealias Policy = MicCaptureProgressPolicy

    private func decide(
        sinceEpoch: TimeInterval = 0,
        delivered: Bool = false,
        rebuilds: Int = 0,
        withoutAudio: TimeInterval? = nil,
    ) -> MicCaptureProgress {
        Policy.decide(
            secondsSinceEpoch: sinceEpoch,
            deliveredSinceEpoch: delivered,
            rebuildsWithoutAudio: rebuilds,
            secondsWithoutAudio: withoutAudio ?? sinceEpoch,
        )
    }

    // MARK: - A capture that is working

    func testABufferSinceTheEpochIsTheWholeAnswer() {
        XCTAssertEqual(decide(sinceEpoch: 3600, delivered: true, rebuilds: 99, withoutAudio: 3600), .healthy)
    }

    func testAFreshCaptureIsGivenItsDeadline() {
        XCTAssertEqual(decide(sinceEpoch: 2.9), .waiting)
    }

    // MARK: - The deadline

    func testPastTheFirstDeadlineWithNothingDeliveredTheEngineIsRebuilt() {
        XCTAssertEqual(decide(sinceEpoch: Policy.firstBufferDeadline), .restart)
    }

    /// Each rebuild gives the device twice as long as the one before, up to a
    /// cap, so a device that is merely slow gets there instead of being
    /// rebuilt on the same clock forever.
    func testEachRebuildGetsALongerDeadlineUpToTheCap() {
        XCTAssertEqual(
            (0 ... 5).map { Policy.bufferDeadline(afterRebuilds: $0) },
            [3, 6, 12, 24, 24, 24],
        )
    }

    /// A headset whose first buffer always takes 3.5 s: the first deadline
    /// rebuilds it, the second is long enough.
    func testASlightlySlowDeviceIsCoveredByTheSecondDeadline() {
        XCTAssertEqual(decide(sinceEpoch: 3.5, rebuilds: 1), .waiting)
    }

    /// Rebuilds alone never give up: only time without audio does, so a slow
    /// device is not ended by being rebuilt a number of times.
    func testNoNumberOfRebuildsGivesUpInsideTheBudget() {
        XCTAssertEqual(
            decide(sinceEpoch: 24, rebuilds: 99, withoutAudio: Policy.maxSecondsWithoutAudio - 0.1),
            .restart,
        )
    }

    // MARK: - The budget

    /// The silent engine of the field recording, told to the user after the
    /// budget instead of after 48 minutes.
    func testASilentEngineIsGivenUpOnceTheBudgetIsSpent() {
        XCTAssertEqual(decide(sinceEpoch: 15, rebuilds: 4, withoutAudio: Policy.maxSecondsWithoutAudio), .giveUp)
    }

    /// Read before the deadline, because in the storm the deadline never
    /// arrives: each adoption starts a new epoch.
    func testTheBudgetEndsAStormWhoseEpochsNeverReachADeadline() {
        XCTAssertEqual(decide(sinceEpoch: 0.2, withoutAudio: Policy.maxSecondsWithoutAudio), .giveUp)
        XCTAssertTrue(Policy.isBudgetSpent(secondsWithoutAudio: Policy.maxSecondsWithoutAudio))
        XCTAssertFalse(Policy.isBudgetSpent(secondsWithoutAudio: Policy.maxSecondsWithoutAudio - 0.1))
    }

    /// The built-in microphone's storm settled after 14 seconds and delivered a
    /// complete track. The budget has to leave that alone with room to spare.
    func testTheBuiltInMicrophoneStormFromTheFieldIsNotGivenUp() {
        XCTAssertEqual(decide(sinceEpoch: 0.2, withoutAudio: 14), .waiting)
        XCTAssertGreaterThanOrEqual(Policy.maxSecondsWithoutAudio, 4 * 14)
    }

    /// The speakerphone storm in issue #706 ran 5.6 minutes and never
    /// delivered. The budget has to end it in a fraction of that.
    func testTheSpeakerphoneStormIsEndedEarly() {
        XCTAssertLessThanOrEqual(Policy.maxSecondsWithoutAudio, 5.6 * 60 / 4)
    }

    /// Delivery outranks everything, however long it took to get there.
    func testDeliveryOutranksTheBudget() {
        XCTAssertEqual(decide(sinceEpoch: 0.2, delivered: true, withoutAudio: 3600), .healthy)
    }

    // MARK: - Retrying a failed rebuild or revival

    /// The retry schedule's own backoff while it has steps left.
    func testAFailedRebuildFollowsTheRetryScheduleWhileItLasts() {
        XCTAssertEqual(Policy.retry(.retry(afterSeconds: 0.6), budgetLeft: 50), .retry(afterSeconds: 0.6))
    }

    /// Past the schedule's count it keeps retrying on the longest step: a
    /// count must not end it while the budget lasts.
    func testAFailedRebuildPastTheScheduleKeepsRetrying() {
        XCTAssertEqual(
            Policy.retry(.giveUp, budgetLeft: 50),
            .retry(afterSeconds: CaptureRestartRetryPolicy.maxBackoff),
        )
    }

    /// Not shortened to the end of the budget: a remainder that rounds to
    /// nothing would schedule a retry due now, forever.
    func testARetryNearTheEndOfTheBudgetKeepsItsStep() {
        XCTAssertEqual(Policy.retry(.giveUp, budgetLeft: 1e-14), .retry(afterSeconds: CaptureRestartRetryPolicy.maxBackoff))
        XCTAssertEqual(Policy.retry(.retry(afterSeconds: 1.2), budgetLeft: 0.5), .retry(afterSeconds: 1.2))
    }

    /// Given up once the budget is spent, whatever the schedule says.
    func testAFailedRebuildIsGivenUpOnceTheBudgetIsSpent() {
        XCTAssertEqual(Policy.retry(.retry(afterSeconds: 0.3), budgetLeft: 0), .giveUp)
        XCTAssertEqual(Policy.retry(.giveUp, budgetLeft: -1), .giveUp)
    }
}
