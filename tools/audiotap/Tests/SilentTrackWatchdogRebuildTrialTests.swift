@testable import AudioTapLib
import XCTest

/// A watchdog rebuild is judged on the tap installed for it (issue #672).
/// Ticks only come with buffers, so a rebuilt tap that never runs an IO cycle
/// (issue #693) needs a deadline; a tap torn down is no longer on trial; and
/// an output device change during the rebuild takes its verdict away, since
/// whatever happens next is the device change's as much as the rebuild's.
final class SilentTrackWatchdogRebuildTrialTests: XCTestCase {
    private typealias Policy = SilentTrackWatchdogPolicy

    private let interval = SilentTrackWatchdogPolicy.minSecondsBetweenChecks
    private let recovery = SilentTrackWatchdogPolicy.recoveryWindowSeconds

    /// Open a check at `now` on a 61 s zero run, conclude it with a process
    /// still rendering, and start the rebuild. Returns its number.
    private func openRebuild(_ policy: inout Policy, at now: TimeInterval) -> Int? {
        guard case .check = policy.tick(ages(energy: 61), now: now),
              case .rebuild? = policy.conclude(anyRunningOutput: true)?.decision,
              policy.beginRebuild(ages(energy: 61), sameTap: true, captureRunning: true) == nil
        else { return nil }
        return policy.rebuildStarted(now: now)
    }

    private func install(_ policy: inout Policy, at now: TimeInterval) -> (rebuild: Int, install: Int)? {
        policy.rebuiltTapInstalled { now }
    }

    // MARK: - The deadline

    func testARebuildNoTickJudgedIsClosedByItsTapsDeadline() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let tap = try XCTUnwrap(install(&policy, at: 1000.5))
        XCTAssertEqual(tap.rebuild, rebuild)

        XCTAssertEqual(
            policy.rebuiltTapDeadlinePassed(rebuild: tap.rebuild, install: tap.install, ages: ages(energy: 80, buffer: 30), now: 1020.5),
            .stalled(rebuild: rebuild, deliveredSinceInstall: false),
        )
        XCTAssertEqual(policy.counters.rebuiltTapStalled, 1)
        XCTAssertEqual(policy.unrecoveredStreak, 1, "it counts against the run's budget like any fruitless rebuild")
        // Closed: if buffers come back later, the next tick opens a new check
        // instead of judging a rebuild that already has its verdict.
        XCTAssertEqual(policy.tick(ages(energy: 200), now: 1000 + interval), .check(zeroRunSeconds: 200))
    }

    /// The tap delivered after its installation and then stopped before a
    /// tick could judge it; the outcome says so, which picks the log wording.
    func testATapThatDeliveredAndStoppedIsToldApart() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let tap = try XCTUnwrap(install(&policy, at: 1000.5))

        // Last buffer at 1001, half a second after the installation.
        XCTAssertEqual(
            policy.rebuiltTapDeadlinePassed(rebuild: tap.rebuild, install: tap.install, ages: ages(energy: 80, buffer: 19.5), now: 1020.5),
            .stalled(rebuild: rebuild, deliveredSinceInstall: true),
        )
    }

    func testADeadlineAfterATickJudgedTheRebuildDoesNothing() throws {
        var policy = Policy()
        _ = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let tap = try XCTUnwrap(install(&policy, at: 1000))
        _ = policy.tick(ages(energy: 61 + recovery), now: 1000 + recovery)

        XCTAssertNil(policy.rebuiltTapDeadlinePassed(rebuild: tap.rebuild, install: tap.install, ages: ages(energy: 90), now: 1020))
        XCTAssertEqual(policy.counters.rebuiltTapStalled, 0)
    }

    /// Rebuild 1's deadline lands after rebuild 2 has started. It must not
    /// close rebuild 2, whose own tap may not even be installed yet.
    func testAStaleDeadlineDoesNotCloseALaterRebuild() throws {
        var policy = Policy()
        _ = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let first = try XCTUnwrap(install(&policy, at: 1000))
        _ = policy.tick(ages(energy: 61 + recovery), now: 1000 + recovery)
        _ = try XCTUnwrap(openRebuild(&policy, at: 1000 + interval))

        XCTAssertNil(policy.rebuiltTapDeadlinePassed(rebuild: first.rebuild, install: first.install, ages: ages(energy: 90), now: 1080))
        XCTAssertEqual(policy.counters.rebuiltTapStalled, 0)
        XCTAssertNotNil(install(&policy, at: 1000 + interval), "rebuild 2 is still open")
    }

    /// Two taps installed for one rebuild (a rate-zero start retried): only
    /// the last is on trial, so the first one's deadline must not close it.
    func testOnlyTheLastInstalledTapsDeadlineCounts() throws {
        var policy = Policy()
        _ = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let earlier = try XCTUnwrap(install(&policy, at: 1001))
        policy.rebuiltTapRemoved()
        let later = try XCTUnwrap(install(&policy, at: 1003))

        XCTAssertNil(policy.rebuiltTapDeadlinePassed(rebuild: earlier.rebuild, install: earlier.install, ages: ages(energy: 90), now: 1021))
        XCTAssertNotNil(policy.rebuiltTapDeadlinePassed(rebuild: later.rebuild, install: later.install, ages: ages(energy: 90), now: 1023))
    }

    /// A rate-zero tap is installed and torn down, and the attempts after it
    /// throw for longer than its deadline. With no tap installed there is
    /// nothing to judge: the deadline closes nothing, the rebuild stays open,
    /// and the restart's give-up is still recorded as ending the channel.
    func testATapTornDownIsNoLongerOnTrial() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let torn = try XCTUnwrap(install(&policy, at: 1001))
        policy.rebuiltTapRemoved()

        XCTAssertNil(policy.rebuiltTapDeadlinePassed(rebuild: torn.rebuild, install: torn.install, ages: ages(energy: 90), now: 1021))
        XCTAssertEqual(policy.counters.rebuiltTapStalled, 0)
        XCTAssertEqual(policy.restartGaveUp(), rebuild)
        XCTAssertTrue(policy.counters.endedChannel)
    }

    func testATapInstalledAfterATornDownOneIsOnTrial() throws {
        var policy = Policy()
        _ = try XCTUnwrap(openRebuild(&policy, at: 1000))
        _ = try XCTUnwrap(install(&policy, at: 1001))
        policy.rebuiltTapRemoved()
        let next = try XCTUnwrap(install(&policy, at: 1030))

        XCTAssertNotNil(policy.rebuiltTapDeadlinePassed(rebuild: next.rebuild, install: next.install, ages: ages(energy: 90), now: 1050))
    }

    func testADeadlineAfterStopDoesNothing() throws {
        var policy = Policy()
        _ = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let tap = try XCTUnwrap(install(&policy, at: 1000))
        policy.stop()

        XCTAssertNil(policy.rebuiltTapDeadlinePassed(rebuild: tap.rebuild, install: tap.install, ages: ages(energy: 90), now: 1020))
    }

    /// The first tick that can judge a delivering tap comes after the window,
    /// at most one report interval late; two intervals leave one spare.
    func testTheDeadlineIsTwoReportIntervalsPastTheWindow() {
        XCTAssertEqual(Policy.rebuiltTapDeadlineSeconds, recovery + 2 * DebugRMSReporter.reportIntervalSeconds)
    }

    // MARK: - The window

    /// The window runs from the tap's installation, not the rebuild's start,
    /// or a restart that backed off past it would lose a rebuild that worked.
    func testTheRecoveryWindowRunsFromTheRebuiltTapsInstallation() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        _ = try XCTUnwrap(install(&policy, at: 1015))

        XCTAssertEqual(policy.tick(ages(energy: 1), now: 1020), .recovered(rebuild: rebuild, withinSeconds: 4))
    }

    /// Neither a tap nor a device change is the watchdog's business while no
    /// rebuild is open, and the clock is not even read.
    func testWithNoRebuildOpenNothingIsOnTrialOrTainted() {
        var policy = Policy()
        XCTAssertNil(policy.rebuiltTapInstalled { XCTFail("clock read with no rebuild open"); return 0 })
        XCTAssertNil(policy.outputDeviceChanged(ages(energy: 1), now: 1000))
        XCTAssertEqual(policy.counters, Policy.Counters())
    }

    // MARK: - An output device change during the rebuild

    /// Signal came back right after the installation and the device changed
    /// before a tick saw it: the recovery is the rebuild's.
    func testSignalBeforeTheDeviceChangeIsCreditedToTheRebuild() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        _ = try XCTUnwrap(install(&policy, at: 1000))

        XCTAssertEqual(
            policy.outputDeviceChanged(ages(energy: 1), now: 1002),
            .recovered(rebuild: rebuild, withinSeconds: 1),
        )
        XCTAssertEqual(policy.counters.recoveries, 1)
        XCTAssertEqual(policy.counters.superseded, 0)
    }

    /// The rebuilt tap stays silent, the user switches output, the device
    /// change's tap delivers: that recovery is not the rebuild's.
    func testSignalAfterTheDeviceChangeIsNotTheRebuilds() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        _ = try XCTUnwrap(install(&policy, at: 1000))

        XCTAssertEqual(policy.outputDeviceChanged(ages(energy: 62), now: 1002), .tainted(rebuild: rebuild))
        _ = try XCTUnwrap(install(&policy, at: 1003))
        XCTAssertEqual(policy.tick(ages(energy: 1), now: 1005), .superseded(rebuild: rebuild))
        XCTAssertEqual(policy.counters.recoveries, 0)
        XCTAssertEqual(policy.counters.superseded, 1)
    }

    /// A device change the restart path ignores still taints the rebuild, and
    /// a deadline that then closes it closes it without a verdict too.
    func testATaintedRebuildsDeadlineWithholdsTheVerdict() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        let tap = try XCTUnwrap(install(&policy, at: 1000))
        _ = policy.outputDeviceChanged(ages(energy: 62), now: 1002)

        XCTAssertEqual(
            policy.rebuiltTapDeadlinePassed(rebuild: tap.rebuild, install: tap.install, ages: ages(energy: 80, buffer: 30), now: 1020),
            .superseded(rebuild: rebuild),
        )
        XCTAssertEqual(policy.counters.rebuiltTapStalled, 0)
    }

    /// A rebuild closed without a verdict is not a strike. Three device
    /// changes during three rebuilds, which is what the app advises, must not
    /// add up to a give-up. No signal anywhere, so no refill hides it.
    func testRebuildsClosedWithoutAVerdictAreNotStrikes() throws {
        var policy = Policy()
        var now = 1000.0
        for _ in 0 ..< Policy.maxUnrecoveredRebuilds {
            let rebuild = try XCTUnwrap(openRebuild(&policy, at: now))
            _ = try XCTUnwrap(install(&policy, at: now))
            _ = policy.outputDeviceChanged(ages(energy: 61 + 2), now: now + 2)
            XCTAssertEqual(policy.tick(ages(energy: 61 + recovery), now: now + recovery), .superseded(rebuild: rebuild))
            now += interval
        }
        XCTAssertEqual(policy.unrecoveredStreak, 0)
        guard case .check = policy.tick(ages(energy: 61), now: now) else {
            XCTFail("no check opened")
            return
        }
        XCTAssertEqual(policy.conclude(anyRunningOutput: true)?.decision, .rebuild)
    }
}
