@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The progress watchdog, driven through the handler's real restart path with
/// a manual clock.
///
/// The field shapes these reproduce (issues #724, #706):
///
/// - the 48-minute case: an engine that reported `Mic recording started`,
///   raised no further configuration change and never delivered a buffer;
/// - the storm: a configuration change about every 200 ms, each restart coming
///   up and delivering nothing before the next;
/// - the control: the built-in microphone ran the same storm, 78 restarts in
///   14 seconds, and then delivered a complete track.
///
/// The revival of a stalled capture is in `MicCaptureRevivalTests`.
@MainActor
final class MicCaptureProgressWatchdogTests: XCTestCase {
    private typealias Policy = MicCaptureProgressPolicy

    private var harness = MicWatchdogHarness()

    override func setUp() {
        super.setUp()
        harness = MicWatchdogHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    // MARK: - The 48-minute case

    /// Started, no configuration change, no buffer. Rebuilt with growing
    /// deadlines at 3, 9, 21 and 45 seconds, then released at 60 and the user
    /// told once, instead of an empty file found after the meeting.
    func testASilentEngineIsRebuiltWithGrowingDeadlinesThenStalls() throws {
        let handler = try harness.makeHandler()

        harness.clock.advance(by: 60 * 48) { settle(handler) }

        XCTAssertEqual(harness.sessions.count, 5, "the first engine plus rebuilds at 3, 9, 21 and 45 s")
        XCTAssertEqual(harness.stalls.count, 1, "one silent track, one notification")
        let stalledAt = try XCTUnwrap(harness.stalls.first)
        XCTAssertEqual(stalledAt, Policy.maxSecondsWithoutAudio, accuracy: 0.001)
        XCTAssertEqual(harness.gaveUp, 0, "a stall is not the terminal give-up of a wedged attempt")
        XCTAssertEqual(harness.clock.pendingCount, 0, "nothing keeps ticking after the stall")
        XCTAssertEqual(
            harness.stallDetails, [MicStallDetails(everDelivered: false, mayRevive: true)],
            "it never delivered, so it did not stop; a change of input can still bring it back",
        )
    }

    /// The stall releases the engine it stalled on; `stop()` skips the engine
    /// of a capture that stalled, and a running one would keep the input open,
    /// holding a headset in its call profile after the user was told.
    func testAStallReleasesItsEngineAndAStopDoesNotReleaseItTwice() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: 120) { settle(handler) }
        let last = try XCTUnwrap(harness.sessions.last)
        XCTAssertEqual(harness.stalls.count, 1)
        XCTAssertEqual(last.teardowns, 1, "released by the stall")

        handler.stop()

        XCTAssertEqual(last.teardowns, 1, "and not a second time by the stop")
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .stopped)
        XCTAssertNil(handler.outputFile, "the stop closes the file the stall kept")
    }

    // MARK: - Devices that are slow, not dead

    /// A headset whose first buffer always takes 3.5 s, because opening the
    /// input is what flips it into its call profile. The first deadline
    /// rebuilds it; the second is long enough, and it is never given up.
    func testADeviceThatAlwaysNeedsThreeAndAHalfSecondsIsNeverGivenUp() throws {
        let handler = try harness.makeHandler()
        var seen = 0
        let between = { [self] in
            settle(handler)
            while seen < harness.sessions.count {
                harness.keepDelivering(harness.sessions[seen], after: 3.5)
                seen += 1
            }
        }
        between()

        harness.clock.advance(by: 600, between: between)

        XCTAssertEqual(harness.stalls, [])
        XCTAssertEqual(harness.sessions.count, 2, "rebuilt once, at the first deadline, and then left alone")
        XCTAssertTrue(handler.isRecording)
    }

    func testAHealthyMicrophoneIsNeverRebuilt() throws {
        let handler = try harness.makeHandler()
        try harness.keepDelivering(XCTUnwrap(harness.sessions.first))

        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.sessions.count, 1)
        XCTAssertEqual(harness.stalls, [])
    }

    /// A rebuild is what could revive the engine, so one that delivers keeps
    /// the track.
    func testARebuildThatDeliversKeepsTheTrack() throws {
        let handler = try harness.makeHandler()
        harness.clock.advance(by: Policy.firstBufferDeadline) { settle(handler) }
        XCTAssertEqual(harness.sessions.count, 2, "the deadline rebuilt the engine")

        try harness.keepDelivering(XCTUnwrap(harness.sessions.last))
        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.sessions.count, 2)
        XCTAssertEqual(harness.stalls, [])
    }

    // MARK: - An engine that stops later

    /// Delivered, then went silent with no configuration change to say so. The
    /// watchdog keeps watching, so this is the same fault seen later: rebuilt
    /// within one deadline of the silence, and released once the budget passes
    /// without audio.
    func testAnEngineThatStopsDeliveringWithoutAChangeIsRebuiltThenStalls() throws {
        let handler = try harness.makeHandler()
        try harness.keepDelivering(XCTUnwrap(harness.sessions.first), until: 10)

        harness.clock.advance(by: 10 + 2 * Policy.firstBufferDeadline) { settle(handler) }
        XCTAssertEqual(harness.sessions.count, 2, "rebuilt within a deadline or two of going silent")
        XCTAssertEqual(harness.stalls, [])

        harness.clock.advance(by: 3600) { settle(handler) }
        let stalledAt = try XCTUnwrap(harness.stalls.first)
        XCTAssertEqual(harness.stalls.count, 1)
        XCTAssertGreaterThanOrEqual(stalledAt, 10 + Policy.maxSecondsWithoutAudio)
        XCTAssertLessThanOrEqual(stalledAt, 10 + Policy.firstBufferDeadline + Policy.maxSecondsWithoutAudio)
        XCTAssertEqual(harness.stallDetails.map(\.everDelivered), [true], "it delivered, then stopped")
    }

    /// Delivery is credited at the last buffer's own time, not at the check
    /// that noticed it, so the budget runs from when the audio actually
    /// stopped.
    func testDeliveryIsCreditedAtTheLastBufferNotAtTheCheck() throws {
        let handler = try harness.makeHandler()
        try XCTUnwrap(harness.sessions.first).deliver()
        // Real time passes between the buffer and the check that sees it.
        Thread.sleep(forTimeInterval: 0.5)
        harness.clock.advance(by: 3600) { settle(handler) }

        let stalledAt = try XCTUnwrap(harness.stalls.first)
        XCTAssertLessThan(
            stalledAt, Policy.firstBufferDeadline + Policy.maxSecondsWithoutAudio - 0.3,
            "counted from the buffer, half a second before the check",
        )
    }

    // MARK: - The storm

    /// Every configuration change restarts the engine at once. An engine stops
    /// itself on a configuration change, so any wait before the restart is
    /// audio lost, and in the built-in microphone's healthy storm it would
    /// have been lost on every one of 78 cycles.
    func testEveryConfigurationChangeRestartsAtOnce() throws {
        let handler = try harness.makeHandler()
        for _ in 0 ..< 5 {
            harness.postConfigChange(handler)
            settle(handler)
        }
        XCTAssertEqual(harness.sessions.count, 6, "five changes, five restarts, and the clock never moved")
    }

    /// The control from the field: the built-in microphone's storm settled and
    /// delivered, and keeps its track.
    func testTheBuiltInStormThatSettlesKeepsItsTrack() throws {
        let handler = try harness.makeHandler()
        runStorm(handler, on: harness, restarts: 78)
        XCTAssertEqual(harness.clock.now - harness.started, 78 * 0.2, accuracy: 0.5, "at the field rate, not slowed")
        XCTAssertEqual(harness.stalls, [], "78 fruitless restarts are what a healthy built-in mic did")

        try harness.keepDelivering(XCTUnwrap(harness.sessions.last))
        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.stalls, [])
        XCTAssertTrue(handler.isRecording)
    }

    /// A storm that never produces a buffer is ended by time: every restart
    /// succeeds and no deadline elapses, so nothing else would.
    func testAStormThatNeverDeliversStallsAtTheBudget() throws {
        let handler = try harness.makeHandler()
        runStorm(handler, on: harness, seconds: Policy.maxSecondsWithoutAudio + 10)

        let stalledAt = try XCTUnwrap(harness.stalls.first)
        XCTAssertEqual(harness.stalls.count, 1)
        XCTAssertGreaterThanOrEqual(stalledAt, Policy.maxSecondsWithoutAudio)
        XCTAssertLessThan(stalledAt, Policy.maxSecondsWithoutAudio + 0.5, "at the first restart past the budget")
        XCTAssertFalse(handler.isRecording)

        let restartsAfterStall = harness.sessions.count
        runStorm(handler, on: harness, seconds: 60)
        XCTAssertEqual(harness.sessions.count, restartsAfterStall, "its observer is gone with its engine")
    }

    /// A switch of the system input just past the budget is the user acting,
    /// often on the silence notice, not the storm going on: it gets its
    /// restart, and that engine its first deadline, instead of the capture
    /// being released on the spot and the user told to switch again.
    func testAnInputSwitchJustPastTheBudgetStillRestarts() throws {
        let handler = try harness.makeHandler()
        runStorm(handler, on: harness, restarts: Int(Policy.maxSecondsWithoutAudio / 0.2) - 10)
        harness.clock.advance(by: 2) { settle(handler) }
        XCTAssertGreaterThan(harness.clock.now - harness.started, Policy.maxSecondsWithoutAudio)
        XCTAssertEqual(harness.stalls, [])
        let before = harness.sessions.count

        handler.handleDeviceChange()
        settle(handler)
        XCTAssertEqual(harness.sessions.count, before + 1, "restarted")
        XCTAssertEqual(harness.stalls, [])

        try harness.keepDelivering(XCTUnwrap(harness.sessions.last), after: 1)
        harness.clock.advance(by: 3600) { settle(handler) }
        XCTAssertEqual(harness.stalls, [])
    }

    /// An engine that never delivered was rebuilt, and the rebuild delivers.
    /// The track begins where the capture started, with the wait bridged as
    /// silence, not at that first buffer: the mixer clamps a microphone delay
    /// to 30 s, so a first buffer later than that would otherwise put the
    /// whole track early in the mix, while the transcript used the real delay.
    func testAFirstBufferAfterARebuildIsPlacedAtTheCaptureStart() throws {
        let startTicks = mach_absolute_time()
        let handler = try harness.makeHandler()
        let url = try XCTUnwrap(harness.url)
        harness.clock.advance(by: Policy.firstBufferDeadline) { settle(handler) }
        XCTAssertEqual(harness.sessions.count, 2, "rebuilt before any buffer")

        // Real time, because the anchor and the first-frame time run on the
        // mach clock.
        Thread.sleep(forTimeInterval: 1)
        let firstTicks = mach_absolute_time()
        try XCTUnwrap(harness.sessions.last).deliver(hostTime: firstTicks)
        handler.stop()

        let origin = machTicksToSeconds(handler.firstFrameTime)
        XCTAssertEqual(origin, machTicksToSeconds(startTicks), accuracy: 0.2, "sample 0 is the capture start")
        let expected = (machTicksToSeconds(firstTicks) - origin) * speechSampleRate + 160
        XCTAssertEqual(try Double(AVAudioFile(forReading: url).length), expected, accuracy: 40)
    }

    /// A storm that settles in the budget's last seconds keeps the engine it
    /// settled on: every engine gets its first deadline to deliver, even when
    /// the budget runs out inside it. A storm that goes on is ended at its
    /// next restart instead.
    func testAStormThatSettlesAtTheEndOfTheBudgetKeepsTheEngineItSettledOn() throws {
        let handler = try harness.makeHandler()
        runStorm(handler, on: harness, restarts: Int(Policy.maxSecondsWithoutAudio / 0.2) - 1)
        XCTAssertGreaterThan(
            harness.clock.now - harness.started, Policy.maxSecondsWithoutAudio - Policy.firstBufferDeadline,
            "settled with less than one deadline of the budget left",
        )

        try harness.keepDelivering(XCTUnwrap(harness.sessions.last), after: 1)
        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.stalls, [])
        XCTAssertTrue(handler.isRecording)
    }

    /// A restart launched inside the budget but adopted after it, here after a
    /// failed attempt's backoff, still gets its first deadline to deliver
    /// instead of being released the moment it is adopted.
    func testARestartAdoptedJustAfterTheBudgetStillGetsItsFirstDeadline() throws {
        let handler = try harness.makeHandler()
        runStorm(handler, on: harness, restarts: Int(Policy.maxSecondsWithoutAudio / 0.2) - 3)
        harness.factory.script([{ $0.shouldThrow = true }])
        harness.clock.advance(by: 0.2) { settle(handler) }
        let launchedAt = harness.clock.now - harness.started
        XCTAssertLessThan(launchedAt, Policy.maxSecondsWithoutAudio, "launched inside the budget")
        XCTAssertGreaterThan(launchedAt + CaptureRestartRetryPolicy.baseBackoff, Policy.maxSecondsWithoutAudio)

        harness.postConfigChange(handler)
        settle(handler)
        harness.clock.advance(by: CaptureRestartRetryPolicy.baseBackoff) { settle(handler) }
        XCTAssertGreaterThan(harness.clock.now - harness.started, Policy.maxSecondsWithoutAudio, "adopted after the budget ran out")
        XCTAssertTrue(handler.isRecording, "the retry was adopted")

        try harness.keepDelivering(XCTUnwrap(harness.sessions.last), after: 1)
        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.stalls, [])
    }

    // MARK: - Adoption boundary

    /// A buffer from the newly adopted engine, landing after the phase flip and
    /// before the adoption is judged, belongs to the new engine's epoch.
    /// Credited to the old one instead, the new epoch would start after it and
    /// rebuild an engine that had delivered.
    func testAnEarlyBufferOfTheNewEngineCountsForItsOwnEpoch() throws {
        harness.factory.script([{ $0.deliverOnObserverInstall = true }])
        let handler = try harness.makeHandler()
        harness.clock.advance(by: Policy.firstBufferDeadline) { settle(handler) }
        XCTAssertEqual(harness.sessions.count, 2)

        harness.clock.advance(by: Policy.bufferDeadline(afterRebuilds: 1)) { settle(handler) }

        XCTAssertEqual(harness.sessions.count, 2, "the new engine delivered in its own epoch")
    }

    // MARK: - Rebuilds that fail, wedge or are stopped

    /// A rebuild whose attempt throws backs off on the same clock, is retried,
    /// and the watchdog carries on with the retried engine.
    func testARebuildThatThrowsIsRetriedAndWatchedOn() throws {
        harness.factory.script([{ $0.shouldThrow = true }])
        let handler = try harness.makeHandler()

        harness.clock.advance(by: Policy.firstBufferDeadline) { settle(handler) }
        XCTAssertEqual(harness.sessions.count, 2, "the rebuild ran and failed")
        harness.clock.advance(by: CaptureRestartRetryPolicy.baseBackoff) { settle(handler) }
        XCTAssertEqual(harness.sessions.count, 3, "retried after its backoff")
        XCTAssertTrue(handler.isRecording)

        try harness.keepDelivering(XCTUnwrap(harness.sessions.last))
        harness.clock.advance(by: 3600) { settle(handler) }
        XCTAssertEqual(harness.sessions.count, 3)
        XCTAssertEqual(harness.stalls, [])
        XCTAssertEqual(harness.gaveUp, 0)
    }

    /// A rebuild whose attempts all throw has nothing wedged and no device
    /// change behind it: the capture stalls rather than giving up, keeps its
    /// file, is told as a stall, and a device change can bring it back.
    func testARebuildWhoseAttemptsAllFailStallsInsteadOfGivingUp() throws {
        harness.factory.script(Array(
            repeating: { $0.shouldThrow = true }, count: CaptureRestartRetryPolicy.maxAttempts + 1,
        ))
        let handler = try harness.makeHandler()

        harness.clock.advance(by: Policy.maxSecondsWithoutAudio) { settle(handler) }

        XCTAssertEqual(harness.gaveUp, 0)
        XCTAssertEqual(harness.stalls.count, 1)
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .stalled)
        XCTAssertNotNil(handler.outputFile)
        handler.handleDeviceChange()
        settle(handler)
        XCTAssertTrue(handler.isRecording, "revived by the next device change")
    }

    /// Only time gives up, a failing rebuild included: its attempts are
    /// retried for as long as the budget lasts, not for the retry schedule's
    /// count, which would release the microphone about nine seconds in.
    /// Measured at the stall itself rather than by advancing past the budget:
    /// at the first failure after the budget, so within one backoff step.
    func testARebuildWhoseAttemptsAllFailStallsAtTheBudgetNotAtTheRetryCount() throws {
        harness.factory.script(Array(repeating: { $0.shouldThrow = true }, count: 200))
        let handler = try harness.makeHandler()

        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.stalls.count, 1)
        let stalledAt = try XCTUnwrap(harness.stalls.first)
        XCTAssertGreaterThanOrEqual(stalledAt, Policy.maxSecondsWithoutAudio)
        XCTAssertLessThanOrEqual(stalledAt, Policy.maxSecondsWithoutAudio + CaptureRestartRetryPolicy.maxBackoff)
        XCTAssertEqual(harness.gaveUp, 0)
    }

    /// How late past the budget that stall can land. Not one retry step: the
    /// budget is read when a failed attempt returns, and an attempt may spend
    /// up to the attempt deadline inside the engine before it throws. Here
    /// the last retry before the budget starts at 61.1 s and fails after
    /// 4.9 s, a hair inside the 5 s deadline, so the capture stalls at 66 s.
    func testAStallAfterASlowFailingAttemptLandsWithinOneStepAndOneAttemptOfTheBudget() throws {
        // The rebuild at 3 s, five retries on the schedule (to 9.1 s), then
        // one every 2 s to 59.1 s: 31 attempts that throw at once. The next,
        // at 61.1 s, is the slow one.
        let fast: [@Sendable (ScriptedMicSession) -> Void] = Array(repeating: { $0.shouldThrow = true }, count: 31)
        harness.factory.script(fast + [{ session in
            session.shouldWedge = true
            session.throwAfterRelease = true
        }])
        let handler = try harness.makeHandler()

        harness.clock.advance(by: 61) { settle(handler) }
        XCTAssertEqual(harness.stalls, [], "still retrying inside the budget")
        harness.clock.advance(by: 0.2) { settle(handler, drainingRestartQueue: false) }
        waitForSessions(harness.factory, count: 33)
        let slow = try XCTUnwrap(harness.sessions.last)
        wait(for: [slow.entered], timeout: 5)
        // It armed its attempt deadline on the main queue before it blocked.
        settle(handler, drainingRestartQueue: false)
        harness.clock.advance(by: RestartArbiter.attemptTimeout - 0.2) { settle(handler, drainingRestartQueue: false) }
        slow.release()
        settle(handler)

        let stalledAt = try XCTUnwrap(harness.stalls.first)
        // The clock when the slow attempt returned: 61.2 s, then the 4.8 s
        // advanced while it was blocked, 4.9 s after it started at 61.1 s.
        XCTAssertEqual(stalledAt, 61 + RestartArbiter.attemptTimeout, accuracy: 0.05, "when the slow attempt failed")
        XCTAssertEqual(harness.gaveUp, 0, "it failed inside its deadline, so it is not a wedge")
        XCTAssertGreaterThan(
            stalledAt, Policy.maxSecondsWithoutAudio + CaptureRestartRetryPolicy.maxBackoff,
            "later than one retry step past the budget",
        )
        XCTAssertLessThanOrEqual(
            stalledAt,
            Policy.maxSecondsWithoutAudio + CaptureRestartRetryPolicy.maxBackoff + RestartArbiter.attemptTimeout,
            "but within one step and one attempt deadline of it",
        )
    }

    /// The field shape behind that: a headset whose engine throws on every
    /// start for longer than the retry schedule runs (about six seconds) while
    /// it changes profile, then comes up and delivers. It keeps its track.
    func testAnEngineThatThrowsLongerThanTheRetryScheduleThenDeliversKeepsItsTrack() throws {
        let failures = CaptureRestartRetryPolicy.maxAttempts + 3
        harness.factory.script(Array(repeating: { $0.shouldThrow = true }, count: failures))
        let handler = try harness.makeHandler()

        harness.clock.advance(by: 20) { settle(handler) }

        XCTAssertEqual(harness.stalls, [], "still inside the budget")
        XCTAssertEqual(harness.sessions.count, failures + 2, "the first engine, the failed attempts and the one that came up")
        try harness.keepDelivering(XCTUnwrap(harness.sessions.last))
        harness.clock.advance(by: 3600) { settle(handler) }
        XCTAssertEqual(harness.stalls, [])
        XCTAssertEqual(harness.gaveUp, 0)
        XCTAssertTrue(handler.isRecording)
    }

    /// A rebuild that wedges is the #588 case: given up at the attempt
    /// deadline, terminally, with the wedged engine never touched and no stall
    /// reported on top of it.
    func testARebuildThatWedgesGivesUpAtTheAttemptDeadline() throws {
        harness.factory.script([{ $0.shouldWedge = true }])
        let handler = try harness.makeHandler()

        harness.clock.advance(by: Policy.firstBufferDeadline) { settle(handler, drainingRestartQueue: false) }
        waitForSessions(harness.factory, count: 2)
        let wedged = try XCTUnwrap(harness.sessions.last)
        wait(for: [wedged.entered], timeout: 5)
        // It armed its deadline on the main queue before it wedged.
        settle(handler, drainingRestartQueue: false)

        harness.clock.advance(by: 3600) { settle(handler, drainingRestartQueue: false) }

        XCTAssertEqual(harness.gaveUp, 1)
        XCTAssertEqual(harness.stalls, [])
        XCTAssertEqual(wedged.teardowns, 0)
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .gaveUp)
    }

    func testAStopDuringAWedgedRebuildLeavesItAlone() throws {
        harness.factory.script([{ $0.shouldWedge = true }])
        let handler = try harness.makeHandler()

        harness.clock.advance(by: Policy.firstBufferDeadline) { settle(handler, drainingRestartQueue: false) }
        waitForSessions(harness.factory, count: 2)
        let wedged = try XCTUnwrap(harness.sessions.last)
        wait(for: [wedged.entered], timeout: 5)
        // It armed its deadline on the main queue before it wedged.
        settle(handler, drainingRestartQueue: false)

        handler.stop()
        harness.clock.advance(by: 3600) { settle(handler, drainingRestartQueue: false) }

        XCTAssertEqual(harness.gaveUp, 0)
        XCTAssertEqual(harness.stalls, [])
        XCTAssertEqual(wedged.teardowns, 0)
    }
}
