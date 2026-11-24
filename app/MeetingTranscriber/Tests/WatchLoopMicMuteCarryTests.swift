@testable import MeetingTranscriber
import XCTest

/// A mic mute across the recording boundaries the watch loop draws by itself.
///
/// A split or the duration cap ends a recording while the call goes on, so a
/// mute the user set in it carries into the next one; a recording whose call
/// ended (the grace expired, or the call was gone by the next poll) starts a
/// meeting of its own, and a mute does not. The manual boundary is pinned by
/// `MicMuteWatchLoopTests.testAMuteDoesNotCarryIntoTheNextRecording`.
///
/// Driven by `TestClock`, so the virtual timelines below run instantly.
@MainActor
final class WatchLoopMicMuteCarryTests: XCTestCase {
    /// Which meetings are live, and in which call, follows a timeline on the
    /// virtual clock: each entry holds from its offset until the next one's.
    /// `checkOnce` reports the last live meeting. No cooldown after a reset,
    /// unlike the production detectors, whose wall-clock cooldown the virtual
    /// timeline would race past.
    private final class ScriptedCallDetector: MeetingDetecting {
        typealias Live = (meeting: DetectedMeeting, call: String)

        private let live: () -> [Live]
        /// False for a detector that cannot tell one call of an app from the
        /// next, as `PowerAssertionDetector` for every app but Teams.
        private let identifiesCalls: Bool

        init(identifiesCalls: Bool = true, _ live: @escaping () -> [Live]) {
            self.identifiesCalls = identifiesCalls
            self.live = live
        }

        func checkOnce() -> DetectedMeeting? {
            live().last?.meeting
        }

        func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
            !calls(of: meeting).isEmpty
        }

        func activeCalls(_ meeting: DetectedMeeting) -> ActiveCalls {
            identifiesCalls ? .ids(calls(of: meeting)) : .unidentified
        }

        private func calls(of meeting: DetectedMeeting) -> Set<String> {
            Set(live().filter { $0.meeting.pattern.appName == meeting.pattern.appName }.map(\.call))
        }

        func reset(appName _: String?) {}
    }

    private static let otherAppMeeting = DetectedMeeting(
        pattern: .zoom, windowTitle: "Zoom Meeting", ownerName: "zoom.us", windowPID: 4343,
    )

    private struct Run {
        var recorders: [MockRecorder] = []
        /// Every reading of `WatchLoop.isMicMuted`, the menu-bar strike, while
        /// the second recording runs.
        var mirrorDuringSecondRecording: Set<Bool> = []
    }

    /// Run the loop over `timeline` for `duration` virtual seconds; with
    /// `muteFirstRecording` the user mutes the first recording as soon as it
    /// can be muted. A non-empty `afterFirstStop` is what is live from
    /// the moment the first recording stops, whatever the timeline says.
    /// `leftOver` is a carry still set when watching starts; `notifier`
    /// answers consent prompts. Without `identifiesCalls` the detector reports
    /// no call IDs. With `failSecondStart` the recording after the first one
    /// cannot start; it is not in `recorders`, so the retry is the second.
    /// With `loseFirstRecording` the first recording's stop finds no audio.
    private func run(
        _ timeline: [(from: TimeInterval, live: [ScriptedCallDetector.Live])],
        for duration: TimeInterval,
        grace: TimeInterval = 0.5,
        maxDuration: TimeInterval = 30,
        muteFirstRecording: Bool = true,
        afterFirstStop: [ScriptedCallDetector.Live] = [],
        leftOver: DetectedMeeting? = nil,
        notifier: any AppNotifying = SilentNotifier(),
        identifiesCalls: Bool = true,
        failSecondStart: Bool = false,
        loseFirstRecording: Bool = false,
    ) async -> Run {
        let clock = TestClock()
        let start = clock.now
        var run = Run()
        var secondStartFailed = false
        let detector = ScriptedCallDetector(identifiesCalls: identifiesCalls) {
            if !afterFirstStop.isEmpty, run.recorders.first?.stopCalled == true { return afterFirstStop }
            return timeline.last { $0.from <= clock.now.timeIntervalSince(start) }?.live ?? []
        }
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: {
                if failSecondStart, run.recorders.count == 1, !secondStartFailed {
                    secondStartFailed = true
                    return ThrowingRecorder()
                }
                let recorder = makeMockRecorder()
                recorder.canMuteMic = true
                if loseFirstRecording, run.recorders.isEmpty { recorder.mixPath = nil }
                run.recorders.append(recorder)
                return recorder
            },
            pollInterval: 0.05, endGracePeriod: grace, maxDuration: maxDuration,
            notifier: notifier, nowProvider: { clock.now }, sleepProvider: { await clock.sleep(for: $0) },
        )

        var muted = !muteFirstRecording
        loop.mutedCallToContinue = leftOver.map { WatchLoop.MutedCall(meeting: $0, calls: .unidentified) }
        loop.start()
        // Wall-clock bail-out: a watch task that exits or parks outside
        // clock.sleep would otherwise leave this loop spinning forever.
        let deadline = Date().addingTimeInterval(10)
        while clock.now.timeIntervalSince(start) < duration, Date() < deadline {
            if !muted, loop.canMuteMic {
                loop.toggleMicMute()
                muted = true
            }
            if run.recorders.count == 2, loop.canMuteMic {
                run.mirrorDuringSecondRecording.insert(loop.isMicMuted)
            }
            await Task.yield()
        }
        loop.stop()
        XCTAssertTrue(muted, "precondition: the first recording was muted")
        XCTAssertEqual(secondStartFailed, failSecondStart, "precondition: the second start failed")
        return run
    }

    private func startedMuted(_ run: Run, file: StaticString = #filePath, line: UInt = #line) -> [Bool] {
        XCTAssertGreaterThanOrEqual(run.recorders.count, 2, "precondition: a second recording", file: file, line: line)
        return run.recorders.prefix(2).map(\.startedMicMuted)
    }

    private let meeting = makeTestMeeting(pid: getpid())

    // MARK: - The call goes on

    func testAMuteCarriesAcrossACallSplit() async {
        let run = await run([(0, [(meeting, "call-A")]), (1.0, [(meeting, "call-B")]), (3.0, [])], for: 2)

        XCTAssertEqual(startedMuted(run), [false, true])
        XCTAssertEqual(run.mirrorDuringSecondRecording, [true], "the menu bar must still show the mute")
    }

    func testAnUnmutedRecordingStartsTheNextCallUnmuted() async {
        let run = await run(
            [(0, [(meeting, "call-A")]), (1.0, [(meeting, "call-B")]), (3.0, [])], for: 2, muteFirstRecording: false,
        )

        XCTAssertEqual(startedMuted(run), [false, false])
        XCTAssertEqual(run.mirrorDuringSecondRecording, [false])
    }

    func testAMuteCarriesAcrossTheDurationCap() async {
        let run = await run([(0, [(meeting, "call-A")])], for: 1.5, maxDuration: 1)

        XCTAssertEqual(startedMuted(run), [false, true])
        XCTAssertEqual(run.mirrorDuringSecondRecording, [true])
    }

    /// Most apps' detection reports no call IDs: there, the app still being
    /// in a meeting at the next poll is what keeps the carry.
    func testAMuteCarriesAcrossTheCapWhereTheDetectorCannotTellCallsApart() async {
        let run = await run([(0, [(meeting, "call-A")])], for: 1.5, maxDuration: 1, identifiesCalls: false)

        XCTAssertEqual(startedMuted(run), [false, true])
    }

    /// A cap that saw no call ID tells nothing about which call goes on, so
    /// the carry stays while the app is in a meeting, as for a detector
    /// without call IDs; no ID set is disjoint from none. The detector reports
    /// a call ID on purpose: one that reports none takes the fallback anyway.
    func testAMuteCapturedWithoutCallIDsCarriesWhileTheAppIsInAMeeting() {
        let detector = ScriptedCallDetector { [(self.meeting, "call-A")] }
        let loop = WatchLoop(detector: detector) { MockRecorder() }
        loop.mutedCallToContinue = WatchLoop.MutedCall(meeting: meeting, calls: .ids([]))
        loop.dropMutedCallIfItEnded()

        XCTAssertNotNil(loop.mutedCallToContinue)
    }

    func testAMuteCapturedWithoutCallIDsDropsOnceTheAppHasNoMeeting() {
        let loop = WatchLoop(detector: ScriptedCallDetector { [] }) { MockRecorder() }
        loop.mutedCallToContinue = WatchLoop.MutedCall(meeting: meeting, calls: .ids([]))
        loop.dropMutedCallIfItEnded()

        XCTAssertNil(loop.mutedCallToContinue)
    }

    /// A start that fails is no recording: the retry, once the error pause is
    /// over, is the one that continues the muted call.
    func testAMuteCarriesPastAStartThatFailed() async {
        let run = await run([(0, [(meeting, "call-A")])], for: 13, maxDuration: 1, failSecondStart: true)

        XCTAssertEqual(startedMuted(run), [false, true])
    }

    /// A recording that loses its audio still ends muted in a call that goes
    /// on: the next one, after the error pause, starts muted.
    func testAMuteCarriesPastTheCapOfARecordingThatLostItsAudio() async {
        let run = await run([(0, [(meeting, "call-A")])], for: 13, maxDuration: 1, loseFirstRecording: true)

        XCTAssertEqual(startedMuted(run), [false, true])
    }

    // MARK: - A meeting of its own

    /// The cap fired inside the grace and the call was gone at the next poll:
    /// what is detected later is not the call that was muted.
    func testAMuteDoesNotCarryPastTheCapWhenTheCallEndsBeforeTheNextRecording() async {
        let run = await run(
            [(0, [(meeting, "call-A")]), (0.8, []), (1.3, [(meeting, "call-A")])],
            for: 2, grace: 100, maxDuration: 1,
        )

        XCTAssertEqual(startedMuted(run), [false, false])
    }

    /// The same, where the detector reports no call IDs: the app has no
    /// meeting at the next poll.
    func testAMuteDoesNotCarryPastTheCapWhenTheMeetingEndsWhereTheDetectorCannotTellCallsApart() async {
        let run = await run(
            [(0, [(meeting, "call-A")]), (0.8, []), (1.3, [(meeting, "call-A")])],
            for: 2, grace: 100, maxDuration: 1, identifiesCalls: false,
        )

        XCTAssertEqual(startedMuted(run), [false, false])
    }

    /// A failed start keeps the carry only while the call goes on: the call
    /// was gone by the poll after the error pause.
    func testAMuteDoesNotCarryPastAStartThatFailedWhenTheCallEndsMeanwhile() async {
        let run = await run(
            [(0, [(meeting, "call-A")]), (2, []), (12, [(meeting, "call-A")])],
            for: 14, maxDuration: 1, failSecondStart: true,
        )

        XCTAssertEqual(startedMuted(run), [false, false])
    }

    /// Even when the same call is back before the next poll, the earliest a
    /// rejoin or a new meeting can show: after the grace there is no telling.
    func testAMuteDoesNotCarryPastAnExpiredGrace() async {
        let run = await run(
            [(0, [(meeting, "call-A")]), (1.0, [])], for: 3, afterFirstStop: [(meeting, "call-A")],
        )

        XCTAssertEqual(startedMuted(run), [false, false])
    }

    /// A carry a stopped session left behind, as stopping watching between a
    /// cap and the next recording leaves it, is not this session's.
    func testANewWatchSessionStartsUnmuted() async {
        let run = await run(
            [(0, [(meeting, "call-A")]), (1.0, [(meeting, "call-B")])], for: 2,
            muteFirstRecording: false, leftOver: meeting,
        )

        XCTAssertEqual(run.recorders.first?.startedMicMuted, false)
    }

    /// The app moved to another call between the cap and the next poll: the
    /// app is still in a meeting, but not in the one that was muted.
    func testAMuteDoesNotCarryPastTheCapIntoAnotherCallOfTheSameApp() async {
        let run = await run(
            [(0, [(meeting, "call-A")])], for: 1.5, maxDuration: 1, afterFirstStop: [(meeting, "call-B")],
        )

        XCTAssertEqual(startedMuted(run), [false, false])
    }

    private final class ApprovingNotifier: AppNotifying {
        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        // swiftlint:disable:next async_without_await
        func askToRecord(title _: String, body _: String) async -> ConsentAnswer {
            .granted
        }
    }

    /// A browser call is asked about again after the cap, and one browser
    /// holds every tab's meetings: the answer starts a recording of its own.
    func testAMuteDoesNotCarryPastTheCapOfAMeetingThatAsksForConsent() async {
        let browser = DetectedMeeting(
            pattern: AppMeetingPattern(
                appName: "Google Chrome", ownerNames: ["Google Chrome"], meetingPatterns: [],
                requiresRecordingConsent: true,
            ),
            windowTitle: "Meet", ownerName: "Google Chrome", windowPID: getpid(),
        )
        let run = await run(
            [(0, [(browser, "tab")])], for: 3, maxDuration: 1, notifier: ApprovingNotifier(),
        )

        XCTAssertEqual(startedMuted(run), [false, false])
    }

    /// A pending carry is the watch loop's; a recording the user starts by
    /// hand does not take it.
    func testAManualRecordingDoesNotTakeAPendingCarry() async throws {
        let recorder = makeMockRecorder()
        let loop = WatchLoop(recorderFactory: { recorder }, pidAliveCheck: { _ in true })
        loop.permissionChecker = { .allHealthy }
        loop.mutedCallToContinue = WatchLoop.MutedCall(meeting: meeting, calls: .unidentified)
        try await loop.startManualRecording(pid: getpid(), appName: meeting.pattern.appName, title: "t")
        addTeardownBlock { await loop.stopManualRecording() }

        XCTAssertFalse(recorder.startedMicMuted)
    }

    /// A recording that started takes the carry with it. Read while the
    /// recording runs: the hand-over at its end writes the carry again, nil
    /// for an unmuted recording, and would hide a carry left in place.
    func testARecordingThatStartedConsumesTheCarry() async {
        let recorder = makeMockRecorder()
        var loop: WatchLoop?
        var carryWhileRecording: [WatchLoop.MutedCall?] = []
        let detector = ScriptedCallDetector {
            if recorder.startCalled, !recorder.stopCalled { carryWhileRecording.append(loop?.mutedCallToContinue) }
            return []
        }
        loop = WatchLoop(detector: detector, recorderFactory: { recorder }, pollInterval: 0.01, endGracePeriod: 0)
        defer { loop = nil }
        loop?.mutedCallToContinue = WatchLoop.MutedCall(meeting: Self.otherAppMeeting, calls: .unidentified)
        _ = try? await loop?.handleMeeting(meeting)

        XCTAssertTrue(recorder.stopCalled, "precondition: the recording ran and stopped")
        XCTAssertFalse(carryWhileRecording.isEmpty, "precondition: the detector was asked while the recording ran")
        XCTAssertFalse(recorder.startedMicMuted, "another app's recording must not take the mute")
        XCTAssertTrue(carryWhileRecording.allSatisfy { $0 == nil }, "the carry is used up once the recording has started")
    }

    func testAMuteDoesNotCarryIntoAnotherAppsCallAfterASplit() async {
        let run = await run([(0, [(meeting, "call-A")]), (1.0, [(meeting, "call-B"), (Self.otherAppMeeting, "call-X")])], for: 2)

        XCTAssertEqual(startedMuted(run), [false, false])
    }
}
