@testable import AudioTapLib
import XCTest

/// The watchdog's second trigger (issue #693): a no-first-buffer probe that
/// finds a tapped process rendering while the tap has delivered nothing opens
/// the same check a zero run would, and its rebuild runs under the same
/// budgets. Pure, like `SilentTrackWatchdogPolicyTests`, whose
/// `ages(energy:buffer:)` helper this shares.
final class SilentTrackWatchdogNoFirstBufferPolicyTests: XCTestCase {
    private typealias Policy = SilentTrackWatchdogPolicy

    private let interval = SilentTrackWatchdogPolicy.minSecondsBetweenChecks

    /// Decide on a probe at `now` for a channel that never delivered
    /// (`.unknown`: no buffer, so no energy either), and when it decides to
    /// rebuild, start that rebuild and put a tap on trial for it.
    @discardableResult
    private func cycle(
        _ policy: inout Policy, now: TimeInterval, running: Bool = true,
    ) -> Policy.Decision? {
        guard let result = policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: running, now: now) else { return nil }
        if case .rebuild = result.decision {
            XCTAssertNil(policy.beginRebuild(.unknown, sameTap: true, captureRunning: true, now: now))
            policy.rebuildStarted(now: now)
            XCTAssertNotNil(policy.rebuiltTapInstalled(now: now + 1))
        }
        return result.decision
    }

    // MARK: - Trigger

    func testAProbeWithNothingOpenOpensACheck() {
        var policy = Policy()
        XCTAssertNotNil(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000))
        XCTAssertEqual(policy.counters.checks, 1)
        XCTAssertEqual(policy.counters.noFirstBufferChecks, 1)
    }

    func testAProcessRenderingTurnsTheCheckIntoARebuildRequest() throws {
        var policy = Policy()
        let result = try XCTUnwrap(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000))
        XCTAssertEqual(result.decision, .rebuild)
        XCTAssertEqual(result.trigger, .noFirstBuffer(afterSeconds: 5))
        XCTAssertNil(policy.beginRebuild(.unknown, sameTap: true, captureRunning: true, now: 1000))
        XCTAssertEqual(policy.rebuildStarted(now: 1000), 1)
        XCTAssertEqual(policy.counters.rebuilds, 1)
    }

    /// An aggregate waiting under `kAudioAggregateDeviceTapAutoStartKey` for
    /// a target that plays nothing is dormant, not dead. It wakes by itself.
    func testNoProcessRenderingDeclines() throws {
        var policy = Policy()
        let result = try XCTUnwrap(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: false, now: 1000))
        XCTAssertEqual(result.decision, .declined(logged: true))
        XCTAssertEqual(policy.counters.declined, 1)
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    /// The probe's reading is already in hand, so a probe that asks for no
    /// rebuild spends no rate limit: the next probe is free to ask, and the
    /// fault is acted on by the first probe that sees it.
    func testADeclinedProbeSpendsNoRateLimit() {
        var policy = Policy()
        XCTAssertEqual(
            policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: false, now: 1000)?.decision,
            .declined(logged: true),
        )
        XCTAssertEqual(policy.noFirstBuffer(afterSeconds: 30, anyRunningOutput: true, now: 1025)?.decision, .rebuild)
    }

    /// Every declined probe is logged, within the skip-line budget: a probe
    /// has no zero run to be logged once per.
    func testEveryDeclinedProbeIsLogged() {
        var policy = Policy()
        XCTAssertEqual(
            policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: false, now: 1000)?.decision,
            .declined(logged: true),
        )
        XCTAssertEqual(
            policy.noFirstBuffer(afterSeconds: 120, anyRunningOutput: false, now: 1115)?.decision,
            .declined(logged: true),
        )
        XCTAssertEqual(policy.counters.declined, 2)
    }

    // MARK: - Re-check before acting

    /// The one question that differs from a zero run: a buffer that arrived
    /// meanwhile, from the tap installed last, means the aggregate started
    /// late, and there is nothing left to rebuild.
    func testABufferThatArrivedMeanwhileDropsTheRequest() {
        var policy = Policy()
        XCTAssertNil(policy.rebuiltTapInstalled(now: 995))
        XCTAssertEqual(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000)?.decision, .rebuild)
        XCTAssertEqual(
            policy.beginRebuild(ages(energy: 0.2, buffer: 0.01), sameTap: true, captureRunning: true, now: 1000.5),
            .buffersArrived,
        )
        XCTAssertEqual(policy.counters.dropped, 1)
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    /// A tap installed by a mid-recording restart that never delivers sits
    /// behind the previous tap's buffers: the ages outlive the tap. A buffer
    /// older than the installation is the previous tap's, and the rebuild
    /// goes ahead.
    func testTheBuffersOfThePreviousTapDoNotDropTheRequest() {
        var policy = Policy()
        XCTAssertNil(policy.rebuiltTapInstalled(now: 995))
        XCTAssertEqual(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000)?.decision, .rebuild)
        // Last buffer at 994.5, half a second before the installation.
        XCTAssertNil(
            policy.beginRebuild(ages(energy: 6, buffer: 6), sameTap: true, captureRunning: true, now: 1000.5),
        )
        XCTAssertEqual(policy.rebuildStarted(now: 1000.5), 1)
    }

    func testAReplacedTapOrAStoppedCaptureDropsTheRequest() {
        var policy = Policy()
        XCTAssertEqual(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000)?.decision, .rebuild)
        XCTAssertEqual(policy.beginRebuild(.unknown, sameTap: false, captureRunning: true, now: 1000), .tapReplaced)

        XCTAssertEqual(
            policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000 + interval)?.decision, .rebuild,
        )
        XCTAssertEqual(
            policy.beginRebuild(.unknown, sameTap: true, captureRunning: false, now: 1000 + interval),
            .captureNotRunning,
        )
    }

    // MARK: - Shared phase, rate limit and budgets

    /// One request per rate-limit interval, counted from the last one: a
    /// probe that finds a process rendering inside it opens nothing.
    func testProbesInsideTheRateLimitOpenNoSecondRequest() {
        var policy = Policy()
        XCTAssertEqual(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000)?.decision, .rebuild)
        policy.rebuildNotStarted()
        XCTAssertNil(policy.noFirstBuffer(afterSeconds: 30, anyRunningOutput: true, now: 1030))
        XCTAssertEqual(policy.counters.checks, 1)
        XCTAssertEqual(policy.noFirstBuffer(afterSeconds: 120, anyRunningOutput: true, now: 1120)?.decision, .rebuild)
    }

    func testAProbeWhileAZeroRunCheckIsOpenOpensNothing() {
        var policy = Policy()
        XCTAssertNotNil(policy.tick(ages(energy: 61), now: 1000))
        XCTAssertNil(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000 + interval))
        XCTAssertNil(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: false, now: 1000 + interval))
        XCTAssertEqual(policy.counters.checks, 1)
    }

    func testAProbeAfterTheStopOpensNothing() {
        var policy = Policy()
        policy.stop()
        XCTAssertNil(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: 1000))
        XCTAssertNil(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: false, now: 1000))
        XCTAssertEqual(policy.counters, Policy.Counters())
    }

    /// A rebuilt tap that delivers nothing either is closed by its deadline,
    /// counted as not restoring signal, and the next probe of the next tap
    /// asks again, until the run's budget ends in one give-up.
    func testRebuiltTapsThatNeverDeliverEndInOneGiveUp() {
        var policy = Policy()
        for rebuild in 1 ... Policy.maxUnrecoveredRebuilds {
            let now = 1000 + Double(rebuild - 1) * interval
            XCTAssertEqual(cycle(&policy, now: now), .rebuild, "rebuild \(rebuild)")
            XCTAssertEqual(
                policy.rebuiltTapDeadlinePassed(rebuild: rebuild, install: rebuild, ages: .unknown, now: now + 20),
                .stalled(rebuild: rebuild, deliveredSinceInstall: false),
            )
        }
        let last = 1000 + Double(Policy.maxUnrecoveredRebuilds) * interval
        XCTAssertEqual(cycle(&policy, now: last), .giveUp)
        XCTAssertEqual(policy.counters.rebuilds, Policy.maxUnrecoveredRebuilds)
        XCTAssertEqual(policy.counters.rebuiltTapStalled, Policy.maxUnrecoveredRebuilds)
        XCTAssertTrue(policy.counters.gaveUp)
        XCTAssertNil(policy.noFirstBuffer(afterSeconds: 5, anyRunningOutput: true, now: last + interval), "nothing after a give-up")
    }

    /// The rebuilt tap delivers signal inside the window: that is what the
    /// rebuild was for, and the run's budget refills.
    func testARebuiltTapThatDeliversIsCreditedToTheRebuild() {
        var policy = Policy()
        XCTAssertEqual(cycle(&policy, now: 1000), .rebuild)
        XCTAssertEqual(
            policy.tick(ages(energy: 0.5, buffer: 0.01), now: 1003),
            .recovered(rebuild: 1, withinSeconds: 1.5),
        )
        XCTAssertEqual(policy.counters.recoveries, 1)
        XCTAssertEqual(policy.unrecoveredStreak, 0)
    }

    /// A rebuilt tap that delivers, but only zeros, in a recording that has
    /// carried no signal yet is judged by the tick its buffers drive, as
    /// unrecovered once the window has passed, like any other rebuild; its
    /// deadline then has nothing left to close. A track with no energy on
    /// record only keeps zero-run checks from opening (issue #524).
    func testARebuiltTapDeliveringOnlyZerosIsJudgedByTheTickAtTheWindow() {
        var policy = Policy()
        XCTAssertEqual(cycle(&policy, now: 1000), .rebuild)
        XCTAssertNil(policy.tick(ages(energy: nil), now: 1005), "inside the window nothing is decided")
        XCTAssertEqual(policy.tick(ages(energy: nil), now: 1011), .unrecovered(rebuild: 1, afterSeconds: 10))
        XCTAssertNil(policy.rebuiltTapDeadlinePassed(rebuild: 1, install: 1, ages: ages(energy: nil), now: 1021))
        XCTAssertEqual(policy.counters.rebuiltTapStalled, 0)
        XCTAssertEqual(policy.unrecoveredStreak, 1)
    }
}
