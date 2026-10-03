@testable import AudioTapLib
import XCTest

/// `SilentTrackWatchdogPolicy` decides when a run of exact zeros on the app
/// track is worth rebuilding the tap for, how often, whether the rebuild
/// helped, and when to stop trying (issue #672). Pure, with the clock passed
/// in, so every threshold is pinned here rather than against a live tap.
/// `ages(energy:buffer:)` is shared with `SilentTrackObserverTests`.
final class SilentTrackWatchdogPolicyTests: XCTestCase {
    private typealias Policy = SilentTrackWatchdogPolicy

    private let window = SilentTrackWatchdogPolicy.triggerZeroRunSeconds
    private let interval = SilentTrackWatchdogPolicy.minSecondsBetweenChecks
    private let recovery = SilentTrackWatchdogPolicy.recoveryWindowSeconds

    /// Open a check at `now`, conclude it, and when it decides to rebuild,
    /// start that rebuild at the same moment. Returns the decision.
    @discardableResult
    private func cycle(
        _ policy: inout Policy, now: TimeInterval, zeroRun: TimeInterval, running: Bool = true,
    ) -> Policy.Decision? {
        guard case .check = policy.tick(ages(energy: zeroRun), now: now) else { return nil }
        guard let result = policy.conclude(anyRunningOutput: running) else { return nil }
        if case .rebuild = result.decision {
            XCTAssertNil(policy.beginRebuild(ages(energy: zeroRun), sameTap: true, captureRunning: true))
            policy.rebuildStarted(now: now)
        }
        return result.decision
    }

    /// Let a started rebuild's recovery window pass with the track still at
    /// zeros, which closes it as unrecovered.
    private func expire(_ policy: inout Policy, startedAt: TimeInterval, zeroRun: TimeInterval) {
        _ = policy.tick(ages(energy: zeroRun + recovery), now: startedAt + recovery)
    }

    /// One full fruitless rebuild: check, rebuild, window passes with zeros.
    private func fruitlessRebuild(_ policy: inout Policy, at now: TimeInterval, zeroRun: TimeInterval) -> Policy.Decision? {
        let decision = cycle(&policy, now: now, zeroRun: zeroRun)
        if case .rebuild = decision { expire(&policy, startedAt: now, zeroRun: zeroRun) }
        return decision
    }

    // MARK: - Trigger

    func testAZeroRunShorterThanTheWindowOpensNoCheck() {
        var policy = Policy()
        XCTAssertNil(policy.tick(ages(energy: window - 0.1), now: 1000))
        XCTAssertEqual(policy.counters, Policy.Counters())
    }

    func testAZeroRunAtTheWindowOpensACheck() {
        var policy = Policy()
        XCTAssertEqual(policy.tick(ages(energy: window), now: 1000), .check(zeroRunSeconds: window))
        XCTAssertEqual(policy.counters.checks, 1)
    }

    /// The observer logs a run from 10 s. Acting at the same moment it is
    /// first logged would leave no line in the log that preceded the action.
    func testTheWindowIsLongerThanTheLoggingThreshold() {
        XCTAssertGreaterThan(window, SilentTrackObserver.zeroRunThreshold)
    }

    /// A channel that never carried a non-zero sample is the tap that was not
    /// allowed to hear the app (issue #524). A rebuild does not grant a
    /// permission.
    func testAChannelThatNeverCarriedSignalIsNotACandidate() {
        var policy = Policy()
        XCTAssertNil(policy.tick(ages(energy: nil), now: 1000))
    }

    func testStaleBuffersOpenNoCheck() {
        var policy = Policy()
        XCTAssertNil(policy.tick(ages(energy: 120, buffer: SilentTrackObserver.maxBufferAge + 0.1), now: 1000))
        XCTAssertNil(policy.tick(ages(energy: 120, buffer: nil), now: 1000))
    }

    // MARK: - isRunningOutput

    func testAProcessStillRenderingTurnsTheCheckIntoARebuildRequest() throws {
        var policy = Policy()
        XCTAssertNotNil(policy.tick(ages(energy: 61), now: 1000))
        let result = try XCTUnwrap(policy.conclude(anyRunningOutput: true))
        XCTAssertEqual(result.decision, .rebuild)
        XCTAssertEqual(result.zeroRunSeconds, 61)
        XCTAssertEqual(policy.counters.rebuilds, 0, "a request is not a rebuild until it starts")
    }

    func testNoProcessRenderingDeclines() throws {
        var policy = Policy()
        XCTAssertNotNil(policy.tick(ages(energy: 61), now: 1000))
        let result = try XCTUnwrap(policy.conclude(anyRunningOutput: false))
        XCTAssertEqual(result.decision, .declined(logged: true))
        XCTAssertEqual(policy.counters.declined, 1)
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    func testDeclinedChecksNeverAddUpToAGiveUp() {
        var policy = Policy()
        for step in 0 ..< 10 {
            let now = 1000 + Double(step) * interval
            if case .declined = cycle(&policy, now: now, zeroRun: 61 + Double(step) * interval, running: false) {} else {
                XCTFail("step \(step) did not decline")
            }
        }
        XCTAssertFalse(policy.counters.gaveUp)
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    // MARK: - Rate limit

    func testNoSecondCheckInsideTheInterval() {
        var policy = Policy()
        _ = fruitlessRebuild(&policy, at: 1000, zeroRun: 61)
        for offset in stride(from: recovery + 5, to: interval, by: 5.0) {
            XCTAssertNil(
                policy.tick(ages(energy: 61 + offset), now: 1000 + offset),
                "a check \(offset) s after a rebuild would rebuild more than once a minute",
            )
        }
        XCTAssertEqual(policy.tick(ages(energy: 61 + interval), now: 1000 + interval), .check(zeroRunSeconds: 61 + interval))
    }

    func testADeclinedCheckAlsoStartsTheInterval() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61, running: false)
        XCTAssertNil(policy.tick(ages(energy: 66), now: 1005))
        XCTAssertNotNil(policy.tick(ages(energy: 121), now: 1000 + interval))
    }

    func testAnOpenCheckBlocksTheNextOne() {
        var policy = Policy()
        XCTAssertNotNil(policy.tick(ages(energy: 61), now: 1000))
        XCTAssertNil(policy.tick(ages(energy: 200), now: 1000 + interval * 2))
        XCTAssertEqual(policy.counters.checks, 1)
    }

    /// A request waiting for the main queue also blocks: two requests in
    /// flight would rebuild twice for one run.
    func testAPendingRebuildBlocksTheNextCheck() {
        var policy = Policy()
        XCTAssertNotNil(policy.tick(ages(energy: 61), now: 1000))
        _ = policy.conclude(anyRunningOutput: true)
        XCTAssertNil(policy.tick(ages(energy: 200), now: 1000 + interval * 2))
    }

    func testAnAbandonedCheckRebuildsNothingAndKeepsTheInterval() {
        var policy = Policy()
        XCTAssertNotNil(policy.tick(ages(energy: 61), now: 1000))
        policy.abandonCheck()
        XCTAssertNil(policy.conclude(anyRunningOutput: true), "nothing is open any more")
        XCTAssertNil(policy.tick(ages(energy: 66), now: 1005))
        XCTAssertNotNil(policy.tick(ages(energy: 121), now: 1000 + interval))
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    func testConcludingWithoutAnOpenCheckDoesNothing() {
        var policy = Policy()
        XCTAssertNil(policy.conclude(anyRunningOutput: true))
        XCTAssertEqual(policy.counters, Policy.Counters())
    }

    // MARK: - Re-check before acting

    private func pendingRequest() -> Policy {
        var policy = Policy()
        _ = policy.tick(ages(energy: 61), now: 1000)
        _ = policy.conclude(anyRunningOutput: true)
        return policy
    }

    /// The decision was taken on a read from another queue; by the time the
    /// main queue gets to it, signal may be back.
    func testARequestIsDroppedWhenSignalCameBack() {
        var policy = pendingRequest()
        XCTAssertEqual(policy.beginRebuild(ages(energy: 0.2), sameTap: true, captureRunning: true), .signalReturned)
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    /// A device-change restart built another tap meanwhile. The one judged
    /// silent is gone; rebuilding the new one acts on a tap nobody looked at.
    func testARequestIsDroppedWhenTheTapWasReplaced() {
        var policy = pendingRequest()
        XCTAssertEqual(policy.beginRebuild(ages(energy: 65), sameTap: false, captureRunning: true), .tapReplaced)
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    func testARequestIsDroppedWhenCaptureIsNotRunning() {
        var policy = pendingRequest()
        XCTAssertEqual(policy.beginRebuild(ages(energy: 65), sameTap: true, captureRunning: false), .captureNotRunning)
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    /// Only a rebuild that actually started is counted and opened. One the
    /// restart path refused (a restart already in flight) is neither.
    func testARebuildTheRestartPathRefusedIsNotCounted() {
        var policy = pendingRequest()
        XCTAssertNil(policy.beginRebuild(ages(energy: 65), sameTap: true, captureRunning: true))
        policy.rebuildNotStarted()
        XCTAssertEqual(policy.counters.rebuilds, 0)
        XCTAssertEqual(policy.unrecoveredStreak, 0)
        XCTAssertNil(policy.tick(ages(energy: 0.1), now: 1003), "nothing open, so nothing to recover")
        XCTAssertEqual(policy.counters.recoveries, 0)
    }

    func testBeginningWithoutARequestDoesNothing() {
        var policy = Policy()
        XCTAssertEqual(policy.beginRebuild(ages(energy: 65), sameTap: true, captureRunning: true), .captureNotRunning)
    }

    /// The recovery window runs from the moment the rebuild started, not from
    /// the check that asked for it.
    func testTheRecoveryWindowStartsWhenTheRebuildStarts() {
        var policy = pendingRequest()
        XCTAssertNil(policy.beginRebuild(ages(energy: 70), sameTap: true, captureRunning: true))
        policy.rebuildStarted(now: 1030)
        XCTAssertEqual(policy.counters.rebuilds, 1)
        XCTAssertEqual(policy.tick(ages(energy: 1), now: 1035), .recovered(rebuild: 1, withinSeconds: 4))
    }

    // MARK: - Recovery

    func testSignalRightAfterARebuildIsARecovery() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61)
        XCTAssertEqual(policy.tick(ages(energy: 1), now: 1005), .recovered(rebuild: 1, withinSeconds: 4))
        XCTAssertEqual(policy.counters.recoveries, 1)
        XCTAssertEqual(policy.unrecoveredStreak, 0)
    }

    /// Signal from before the rebuild is not a recovery. The zero run keeps
    /// growing across the rebuild because the level publisher outlives the tap.
    func testOnlySignalAfterTheRebuildCounts() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61)
        XCTAssertNil(policy.tick(ages(energy: 66), now: 1005))
        XCTAssertEqual(policy.counters.recoveries, 0)
    }

    /// A restored tap delivers at once; signal that only turns up after the
    /// window is a participant resuming, and crediting it to the rebuild is
    /// the evidence this whole feature exists to collect, corrupted.
    func testSignalAfterTheWindowIsNotCreditedToTheRebuild() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61)
        XCTAssertEqual(
            policy.tick(ages(energy: 61 + recovery), now: 1000 + recovery),
            .unrecovered(rebuild: 1, afterSeconds: recovery),
        )
        XCTAssertNil(policy.tick(ages(energy: 0.5), now: 1000 + recovery + 5))
        XCTAssertEqual(policy.counters.recoveries, 0)
    }

    func testARecoveryIsReportedOnce() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61)
        XCTAssertNotNil(policy.tick(ages(energy: 1), now: 1005))
        XCTAssertNil(policy.tick(ages(energy: 0.1), now: 1010))
        XCTAssertEqual(policy.counters.recoveries, 1)
    }

    // MARK: - Budget

    func testThreeUnrecoveredRebuildsThenAGiveUp() {
        var policy = Policy()
        var decisions: [Policy.Decision?] = []
        for step in 0 ..< 4 {
            let now = 1000 + Double(step) * interval
            decisions.append(fruitlessRebuild(&policy, at: now, zeroRun: 61 + Double(step) * interval))
        }
        XCTAssertEqual(decisions, [.rebuild, .rebuild, .rebuild, .giveUp])
        XCTAssertTrue(policy.counters.gaveUp)
        XCTAssertEqual(policy.counters.rebuilds, Policy.maxUnrecoveredRebuilds)
    }

    func testNothingAfterAGiveUp() {
        var policy = Policy()
        for step in 0 ..< 4 {
            _ = fruitlessRebuild(&policy, at: 1000 + Double(step) * interval, zeroRun: 61 + Double(step) * interval)
        }
        XCTAssertTrue(policy.counters.gaveUp)
        let checks = policy.counters.checks
        for step in 4 ..< 20 {
            XCTAssertNil(policy.tick(ages(energy: 61 + Double(step) * interval), now: 1000 + Double(step) * interval))
        }
        XCTAssertEqual(policy.counters.checks, checks, "a give-up is final for the recording")
    }

    func testTheGiveUpNeedsAProcessStillRendering() {
        var policy = Policy()
        for step in 0 ..< 3 {
            _ = fruitlessRebuild(&policy, at: 1000 + Double(step) * interval, zeroRun: 61 + Double(step) * interval)
        }
        if case .declined = cycle(&policy, now: 1000 + 3 * interval, zeroRun: 61 + 3 * interval, running: false) {} else {
            XCTFail("expected a decline")
        }
        XCTAssertFalse(policy.counters.gaveUp)
    }

    /// The budget is per zero run. Signal coming back on its own ends the run,
    /// whether or not a check happened to be declined in between, and the next
    /// dead stretch gets the full budget rather than whatever the last one
    /// left. Not a recovery: nothing the watchdog did brought it back.
    func testANaturalReturnOfSignalRefillsTheBudgetWithoutCountingARecovery() {
        var policy = Policy()
        _ = fruitlessRebuild(&policy, at: 1000, zeroRun: 61)
        _ = fruitlessRebuild(&policy, at: 1000 + interval, zeroRun: 61 + interval)
        cycle(&policy, now: 1000 + 2 * interval, zeroRun: 61 + 2 * interval, running: false)
        XCTAssertEqual(policy.unrecoveredStreak, 2)

        XCTAssertNil(policy.tick(ages(energy: 0.3), now: 1000 + 2 * interval + 30))
        XCTAssertEqual(policy.unrecoveredStreak, 0)
        XCTAssertEqual(policy.counters.recoveries, 0)

        let base = 2000.0
        var decisions: [Policy.Decision?] = []
        for step in 0 ..< 4 {
            let now = base + Double(step) * interval
            decisions.append(fruitlessRebuild(&policy, at: now, zeroRun: 61 + Double(step) * interval))
        }
        XCTAssertEqual(decisions, [.rebuild, .rebuild, .rebuild, .giveUp])
    }

    /// However often signal comes back, the recording gets at most this many
    /// rebuilds: each one is an exposure to the restart wedge of issue #588.
    func testATotalCapBoundsRebuildsAcrossRefills() {
        var policy = Policy()
        var now = 1000.0
        var decisions: [Policy.Decision] = []
        for _ in 0 ..< 20 {
            if let decision = cycle(&policy, now: now, zeroRun: 61) {
                decisions.append(decision)
                if decision == .capReached { break }
            }
            // Restored at once: every rebuild recovers, so only the cap stops it.
            _ = policy.tick(ages(energy: 0.5), now: now + 2)
            now += interval + 61
        }
        XCTAssertEqual(decisions.filter { $0 == .rebuild }.count, Policy.maxRebuildsPerRecording)
        XCTAssertEqual(decisions.last, .capReached)
        XCTAssertEqual(policy.counters.rebuilds, Policy.maxRebuildsPerRecording)
        XCTAssertTrue(policy.counters.capped)
        XCTAssertFalse(policy.counters.gaveUp, "the cap is not a verdict on the tap")
        XCTAssertNil(policy.tick(ages(energy: 200), now: now + 1000), "nothing after the cap")
    }

    // MARK: - Stop

    /// A probe that answers after the recording stopped must change nothing:
    /// its lines and counters would land after the stop summary.
    func testNothingIsConcludedAfterStop() {
        var policy = Policy()
        XCTAssertNotNil(policy.tick(ages(energy: 61), now: 1000))
        policy.stop()
        XCTAssertNil(policy.conclude(anyRunningOutput: true))
        XCTAssertEqual(policy.beginRebuild(ages(energy: 61), sameTap: true, captureRunning: true), .captureNotRunning)
        XCTAssertNil(policy.tick(ages(energy: 200), now: 5000))
        XCTAssertEqual(policy.counters.rebuilds, 0)
    }

    // MARK: - Logging bound

    /// Declines are logged once per zero run, and at most this many per
    /// recording, so a meeting app sitting in its lobby for an hour cannot
    /// crowd out the lines of a real tap death later on. Rebuilds are not
    /// under this budget: the total cap already bounds them.
    func testDeclinesAreLoggedOncePerRunAndBounded() {
        var policy = Policy()
        var logged = 0
        var now = 1000.0
        for run in 0 ..< (Policy.maxLoggedSkips + 5) {
            var flags: [Bool] = []
            for _ in 0 ..< 3 {
                if case let .declined(isLogged) = cycle(&policy, now: now, zeroRun: 61, running: false) {
                    flags.append(isLogged)
                    if isLogged { logged += 1 }
                }
                now += interval
            }
            let expected = run < Policy.maxLoggedSkips ? [true, false, false] : [false, false, false]
            XCTAssertEqual(flags, expected, "run \(run)")
            _ = policy.tick(ages(energy: 0.5), now: now)
            now += 1
        }
        XCTAssertEqual(logged, Policy.maxLoggedSkips)
        XCTAssertEqual(policy.counters.declined, (Policy.maxLoggedSkips + 5) * 3)
    }

    // MARK: - A late first tick

    /// Ticks only come with buffers, so after a slow or backed-off restart the
    /// first one can land well after the recovery window. What decides is when
    /// the signal arrived, not when a tick happened to see it: speech 20 s
    /// after the start is a participant, not the rebuild.
    func testALateFirstTickDoesNotCreditSignalFromAfterTheWindow() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61)
        XCTAssertEqual(
            policy.tick(ages(energy: 5), now: 1025),
            .unrecovered(rebuild: 1, afterSeconds: 25),
        )
        XCTAssertEqual(policy.counters.recoveries, 0)
    }

    func testALateFirstTickStillCreditsSignalFromInsideTheWindow() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61)
        XCTAssertEqual(
            policy.tick(ages(energy: 20), now: 1025),
            .recovered(rebuild: 1, withinSeconds: 5),
        )
        XCTAssertEqual(policy.counters.recoveries, 1)
    }

    // MARK: - A restart that gave up

    /// A rebuild runs through the device-change restart path, which can give
    /// up (retry budget, or an attempt that never returns, issue #588). That
    /// rebuild ended the channel, and the record has to say so.
    func testARestartGiveUpDuringARebuildEndsTheWatchdog() {
        var policy = Policy()
        cycle(&policy, now: 1000, zeroRun: 61)
        XCTAssertEqual(policy.restartGaveUp(), 1)
        XCTAssertTrue(policy.counters.endedChannel)
        XCTAssertNil(policy.tick(ages(energy: 1), now: 1005), "no recovery for a channel that ended")
        XCTAssertNil(policy.tick(ages(energy: 200), now: 5000), "and no further checks")
        XCTAssertEqual(policy.counters.recoveries, 0)
    }

    /// A restart give-up with no watchdog rebuild open is a device change's,
    /// not the watchdog's, and is not attributed to it.
    func testARestartGiveUpWithoutARebuildOpenIsNotTheWatchdogs() {
        var policy = Policy()
        XCTAssertNil(policy.restartGaveUp())
        XCTAssertFalse(policy.counters.endedChannel)
    }

    // MARK: - The summary adds up

    /// Every check ends as exactly one of: declined, a started rebuild,
    /// dropped (probe busy, dropped on re-check, refused by the restart path),
    /// the give-up, the cap, or still open. The stop summary has a counter for
    /// each, so a reader can tell where every check went.
    func testEveryCheckIsAccountedFor() {
        var policy = Policy()
        var now = 1000.0
        func next() -> TimeInterval {
            now += interval
            return now
        }
        // Declined.
        cycle(&policy, now: next(), zeroRun: 61, running: false)
        // Probe busy.
        _ = policy.tick(ages(energy: 61), now: next())
        policy.abandonCheck()
        // Dropped on re-check.
        _ = policy.tick(ages(energy: 61), now: next())
        _ = policy.conclude(anyRunningOutput: true)
        _ = policy.beginRebuild(ages(energy: 0.2), sameTap: true, captureRunning: true)
        // Refused by the restart path.
        _ = policy.tick(ages(energy: 61), now: next())
        _ = policy.conclude(anyRunningOutput: true)
        XCTAssertNil(policy.beginRebuild(ages(energy: 61), sameTap: true, captureRunning: true))
        policy.rebuildNotStarted()
        // Three started, fruitless, then the give-up.
        for _ in 0 ..< 4 {
            let at = next()
            if case .rebuild = cycle(&policy, now: at, zeroRun: 61) {
                expire(&policy, startedAt: at, zeroRun: 61)
            }
        }
        let counters = policy.counters
        XCTAssertEqual(counters.dropped, 3)
        XCTAssertEqual(counters.declined, 1)
        XCTAssertEqual(counters.rebuilds, 3)
        XCTAssertTrue(counters.gaveUp)
        XCTAssertEqual(
            counters.checks,
            counters.declined + counters.rebuilds + counters.dropped + (counters.gaveUp ? 1 : 0) + (counters.capped ? 1 : 0),
        )
    }
}

// MARK: - A rebuilt tap that never delivers

// Ticks only come with buffers. A rebuild whose new tap starts but never runs
// an IO cycle (issue #693) would otherwise wait for a verdict forever, so the
// tap's installation arms a deadline that closes it. An extension only to keep
// the class body inside the length limit.
extension SilentTrackWatchdogPolicyTests {
    private func openRebuild(_ policy: inout Policy, at now: TimeInterval) -> Int? {
        guard case .rebuild = cycle(&policy, now: now, zeroRun: 61) else { return nil }
        return policy.counters.rebuilds
    }

    func testARebuildWhoseTapDeliveredNothingIsClosedByItsDeadline() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        XCTAssertEqual(policy.rebuildAwaitingFirstBuffer, rebuild, "the installed tap arms a deadline for it")

        XCTAssertTrue(policy.rebuiltTapDeadlinePassed(rebuild: rebuild))
        XCTAssertEqual(policy.counters.rebuiltTapSilent, 1)
        XCTAssertEqual(policy.unrecoveredStreak, 1, "it counts against the run's budget like any fruitless rebuild")
        XCTAssertNil(policy.rebuildAwaitingFirstBuffer)
        // Closed: if buffers come back later, the next tick opens a new check
        // instead of judging a rebuild that already has its verdict.
        XCTAssertEqual(policy.tick(ages(energy: 200), now: 1000 + interval), .check(zeroRunSeconds: 200))
    }

    func testARebuildWhoseTapDeliveredIsLeftToTheTick() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        policy.rebuiltTapDelivered()

        XCTAssertNil(policy.rebuildAwaitingFirstBuffer)
        XCTAssertFalse(policy.rebuiltTapDeadlinePassed(rebuild: rebuild))
        XCTAssertEqual(policy.counters.rebuiltTapSilent, 0)
        XCTAssertEqual(
            policy.tick(ages(energy: 1), now: 1005), .recovered(rebuild: rebuild, withinSeconds: 4),
            "still open, and judged the usual way",
        )
    }

    /// Rebuild 1's deadline lands after rebuild 2 has started. It must not
    /// close rebuild 2, whose own tap has had no chance to deliver yet.
    func testAStaleDeadlineDoesNotCloseALaterRebuild() throws {
        var policy = Policy()
        let first = try XCTUnwrap(openRebuild(&policy, at: 1000))
        policy.rebuiltTapDelivered()
        expire(&policy, startedAt: 1000, zeroRun: 61)
        let second = try XCTUnwrap(openRebuild(&policy, at: 1000 + interval))
        XCTAssertNotEqual(first, second, "precondition")

        XCTAssertFalse(policy.rebuiltTapDeadlinePassed(rebuild: first))
        XCTAssertEqual(policy.counters.rebuiltTapSilent, 0)
        XCTAssertEqual(policy.rebuildAwaitingFirstBuffer, second, "rebuild 2 is still open")
    }

    /// The delivery of one rebuild's tap says nothing about the next one's.
    func testTheNextRebuildWaitsForItsOwnFirstBuffer() throws {
        var policy = Policy()
        _ = try XCTUnwrap(openRebuild(&policy, at: 1000))
        policy.rebuiltTapDelivered()
        expire(&policy, startedAt: 1000, zeroRun: 61)
        let second = try XCTUnwrap(openRebuild(&policy, at: 1000 + interval))

        XCTAssertTrue(policy.rebuiltTapDeadlinePassed(rebuild: second))
    }

    func testADeadlineAfterTheTickJudgedTheRebuildDoesNothing() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        expire(&policy, startedAt: 1000, zeroRun: 61)

        XCTAssertFalse(policy.rebuiltTapDeadlinePassed(rebuild: rebuild))
        XCTAssertEqual(policy.counters.rebuiltTapSilent, 0)
    }

    func testADeadlineAfterStopDoesNothing() throws {
        var policy = Policy()
        let rebuild = try XCTUnwrap(openRebuild(&policy, at: 1000))
        policy.stop()

        XCTAssertFalse(policy.rebuiltTapDeadlinePassed(rebuild: rebuild))
        XCTAssertEqual(policy.counters.rebuiltTapSilent, 0)
    }

    func testNoRebuildOpenArmsNothing() {
        var policy = Policy()
        XCTAssertNil(policy.rebuildAwaitingFirstBuffer)
        policy.rebuiltTapDelivered()
        XCTAssertEqual(policy.counters, Policy.Counters(), "a first buffer outside a rebuild changes nothing")
    }
}
