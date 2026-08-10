@testable import MeetingTranscriber
import XCTest

/// Unit tests for `WatchingController` exercised on a bare controller (no full
/// `AppState`), focusing on the genuinely-new injection seams the extraction
/// enables: `ensureMicAccess` and `makeDetector`. Before the split,
/// `toggleWatching` hard-wired `Permissions.ensureMicrophoneAccess()` +
/// `PowerAssertionDetector()`, so neither the mic-access gate nor the detector
/// wiring was reachable in a unit test without real TCC / IOKit.
@MainActor
final class WatchingControllerTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// Builds a `WatchingController` wired to real (but inert) sibling
    /// controllers and the supplied seams. The pipeline gets a queue on an
    /// isolated `logDir` so `rebuild()` touches no production path, and the
    /// default detector never matches a window so no recording starts.
    private func makeController(
        ensureMicAccess: @escaping () async -> Bool = { true },
        requestScreenRecording: @escaping () -> Void = {},
        requestAccessibility: @escaping () -> Void = {},
        watchTeams: Bool = true,
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
        makeDetector: @escaping () -> any MeetingDetecting = { makeSilentDetector() },
    ) -> WatchingController {
        let settings = AppSettings()
        settings.watchTeams = watchTeams
        let notifier = RecordingNotifier()
        let pipeline = PipelineController(settings: settings, notifier: notifier)
        pipeline.queue = PipelineQueue(logDir: tmpDir)
        let channelHealth = ChannelHealthController(
            notifier: notifier,
            debounceSeconds: { 0 },
            indicatorEnabled: { false },
        )
        let permissions = PermissionsController(notifier: notifier)
        let liveTranscription = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { false },
            engineSupportsLive: { false },
            verboseDiagnostics: { false },
        )
        return WatchingController(
            settings: settings,
            notifier: notifier,
            pipeline: pipeline,
            channelHealth: channelHealth,
            permissions: permissions,
            liveTranscription: liveTranscription,
            ensureMicAccess: ensureMicAccess,
            requestScreenRecording: requestScreenRecording,
            requestAccessibility: requestAccessibility,
            startJoinTimeout: startJoinTimeout,
            makeDetector: makeDetector,
        )
    }

    // MARK: - requestScreenRecording seam

    /// Asking is what registers the app in the Screen Recording list, and until
    /// it is listed there is no switch for the user to turn on. It belongs at
    /// watch start, where the window-title lookup that needs it happens — not
    /// in the health check, which runs on every activation and would re-ask a
    /// user who is trying to work.
    func testToggleWatchingRequestsScreenRecording() async {
        var requested = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`makeDetector`), not `requestScreenRecording`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(requestScreenRecording: { requested = true })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(requested)

        XCTAssertTrue(requested, "toggleWatching must ask for Screen Recording")
    }

    // MARK: - requestAccessibility seam

    /// The health check already flags a missing Accessibility grant with a red
    /// menu-bar badge and a notification, but nothing used to ask for it, so the
    /// app reported a problem it never offered to fix. Asking on a deliberate
    /// Start Watching — where the participant read that needs it happens — is
    /// what closes that gap, and pinning it here keeps the request from being
    /// dropped again.
    func testToggleWatchingRequestsAccessibility() async {
        var requested = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`makeDetector`), not `requestAccessibility`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(requestAccessibility: { requested = true })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(requested)

        XCTAssertTrue(requested, "toggleWatching must ask for Accessibility")
    }

    /// The roster read is the grant's only consumer and is itself Teams-gated,
    /// so someone watching only Zoom, Webex or a browser must never be asked for
    /// full computer control. The prompt also used to burn a process-wide
    /// one-shot, so enabling Teams later in the same session then never asked
    /// for the grant that had by then become necessary.
    func testToggleWatchingSkipsAccessibilityWhenTeamsNotWatched() async {
        var requested = false
        let controller = makeController(
            requestAccessibility: { requested = true },
            watchTeams: false,
        )
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(controller.watchLoop != nil)

        XCTAssertFalse(requested, "watchTeams off must not ask for Accessibility")
    }

    /// Auto-watch reaches `toggleWatching` three seconds after launch with no
    /// click of any kind, so an unconditional request raised a system alert on
    /// every launch. It also fires mid-lane on the e2e runners, which force
    /// auto-watch on, where a dialog can take the keystroke the naming lane
    /// sends and fail it for a reason unrelated to the code under test.
    func testAutoWatchStartDoesNotRequestAccessibility() async {
        var requested = false
        // swiftlint:disable:next trailing_closure
        let controller = makeController(requestAccessibility: { requested = true })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching(userInitiated: false)
        await waitFor(controller.watchLoop != nil)

        XCTAssertFalse(requested, "auto-watch must not ask for Accessibility")
    }

    // MARK: - ensureMicAccess seam

    func testToggleWatchingAwaitsInjectedMicAccess() async {
        var micAccessCalled = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`makeDetector`), not `ensureMicAccess`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            micAccessCalled = true
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(micAccessCalled)

        XCTAssertTrue(micAccessCalled, "toggleWatching must await the injected mic-access gate")
    }

    func testStartManualRecordingAwaitsInjectedMicAccess() async {
        var micAccessCalled = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`makeDetector`), not `ensureMicAccess`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            micAccessCalled = true
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(micAccessCalled)

        XCTAssertTrue(micAccessCalled, "startManualRecording must await the injected mic-access gate")
    }

    // MARK: - makeDetector seam

    func testToggleWatchingUsesInjectedDetectorFactory() async {
        var detectorMade = false
        // Not trailing-closure: with `ensureMicAccess` defaulted before it, a
        // trailing closure binds to `ensureMicAccess` (→ `Bool`), not `makeDetector`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(makeDetector: {
            detectorMade = true
            return makeSilentDetector()
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(detectorMade)

        XCTAssertTrue(detectorMade, "toggleWatching must build its detector via the injected factory")
    }

    // MARK: - Toggle / stop lifecycle

    func testToggleWatchingCreatesLoopThenSecondToggleStops() async {
        let controller = makeController()
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(controller.watchLoop?.isActive == true)
        XCTAssertEqual(controller.watchLoop?.isActive, true, "first toggle should start an active loop")

        controller.toggleWatching()
        XCTAssertNil(controller.watchLoop, "second toggle should stop and clear the loop")
    }

    func testReentrantToggleWhileStartingStartsOnlyOneLoop() async {
        // The start path is async: it awaits mic access before it assigns
        // `watchLoop`. A second toggle fired in that window sees `watchLoop ==
        // nil` and, without a guard, launches a *second* start — duplicating the
        // queue rebuild and leaving an orphan WatchLoop running. The mic-access
        // gate counts starts: a re-entrant toggle must not trip it twice.
        var startAttempts = 0
        // Not trailing-closure: a trailing closure binds to the last param
        // (`makeDetector`), not `ensureMicAccess`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            startAttempts += 1
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        // Two toggles back-to-back, before the first start can finish.
        controller.toggleWatching()
        controller.toggleWatching()

        await waitFor(controller.watchLoop != nil)
        XCTAssertEqual(startAttempts, 1, "a re-entrant toggle during start must not launch a second WatchLoop")
    }

    func testToggleWatchingNoOpWhileManualRecording() async throws {
        let controller = makeController()
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        controller.toggleWatching() // must be a no-op while a manual recording is live

        XCTAssertNotNil(controller.watchLoop)
        XCTAssertEqual(controller.watchLoop?.isManualRecording, true)
    }

    func testStopManualRecordingClearsLoop() async throws {
        let controller = makeController()
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")

        controller.stopManualRecording()

        XCTAssertNil(controller.watchLoop)
    }

    // MARK: - Idempotent control (automation API)

    /// A manual start can register while the auto start is parked on the
    /// permission gate, and nothing below that gate re-checked. Whichever side
    /// assigned `watchLoop` last won, orphaning the other — still running, with
    /// no reference left to stop it. The auto loop is the worse orphan: it keeps
    /// polling and starts a second concurrent recording on the next detected
    /// meeting, invisible in the UI.
    ///
    /// Separate gates per call so the manual start stays parked, and therefore
    /// registered, for the whole of the auto task's resume. Sharing one gate
    /// leaves the resume order undefined.
    func testParkedAutoStartBailsWhileAManualStartIsInFlight() async {
        let autoGate = AsyncGate()
        let manualGate = AsyncGate()
        let calls = CallCounter()
        let controller = makeController(
            ensureMicAccess: {
                let n = await calls.next()
                await (n == 0 ? autoGate : manualGate).wait()
                return true
            },
            // Short, so the manual path's own `joinStart` gives up on the parked
            // auto start rather than waiting it out. That giving-up is the case
            // the guard exists for: past the bound both paths run concurrently.
            startJoinTimeout: .milliseconds(50),
        )
        addTeardownBlock {
            await manualGate.open()
            await controller.watchLoop?.stop()
        }

        controller.toggleWatching()
        await waitFor { await autoGate.hasWaiter }
        controller.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
        await waitFor { await manualGate.hasWaiter }

        await autoGate.open()
        // Joins the auto task, so the assertion below is not a race.
        let outcome = await controller.stopWatching()

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertNil(controller.watchLoop, "the parked auto start must not assign over an in-flight manual start")
    }

    /// The bail path must report the refusal it is. When a manual start
    /// registers while the auto start is parked, that start bails and
    /// `watchLoop` stays nil — but the join *settled* and the dialog *was*
    /// answered, so `.failed` (503, documented as "did not settle within 20
    /// seconds") describes something that did not happen. It is the conflict
    /// 409 exists for, and the body carries `manualRecording: true` either way.
    func testStartRefusedByAMidFlightManualStartReportsBlocked() async {
        let micGate = AsyncGate()
        let box = ControllerBox()
        let controller = makeController(
            ensureMicAccess: {
                await micGate.wait()
                return true
            },
            // Fires inside the auto start task after the mic gate and before
            // the bail guard. Registering the manual start from there orders
            // the race instead of betting on it: the entry guard of
            // `startWatching` has provably already run.
            requestScreenRecording: {
                MainActor.assumeIsolated {
                    box.controller?.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
                }
            },
        )
        box.controller = controller
        addTeardownBlock {
            await micGate.open()
            await controller.watchLoop?.stop()
        }

        async let starting = controller.startWatching()
        // The auto task exists only because `startWatching` created it, so
        // waiting for it to park also pins that the entry guard saw no manual
        // recording.
        await waitFor { await micGate.hasWaiter }
        await micGate.open()

        let outcome = await starting

        XCTAssertEqual(outcome, .blocked, "a start refused by a manual recording is a conflict, not a timeout")
    }

    /// `toggleWatching` guards re-entry with `startTask`; the manual path had no
    /// counterpart. Two starts in quick succession both ran, the second replaced
    /// the field, and the first's `defer` then cleared the second's
    /// registration while it was still in flight — reopening the window that
    /// `isManualRecording` was widened to close.
    func testSecondManualStartWhileOneIsInFlightIsIgnored() async {
        let micGate = AsyncGate()
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            await micGate.wait()
            return true
        })
        addTeardownBlock {
            await micGate.open()
            await controller.watchLoop?.stop()
        }

        controller.startManualRecording(pid: 1, appName: "Chrome", title: "First")
        await waitFor { await micGate.hasWaiter }
        controller.startManualRecording(pid: 2, appName: "Chrome", title: "Second")
        // Let a second task run if the guard failed to stop one being created.
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        let waiters = await micGate.waiterCount
        XCTAssertEqual(waiters, 1, "a second manual start must not run while one is in flight")
    }

    /// A remote start arrives at a machine nobody is sitting at, so it must not
    /// raise the optional Accessibility prompt — the same reason auto-watch does
    /// not. `toggleWatching`'s parameter defaults to true for the menu bar, so a
    /// bare call here would silently opt the API into prompting.
    func testRemoteStartDoesNotRequestAccessibility() async {
        var requested = false
        // swiftlint:disable:next trailing_closure
        let controller = makeController(requestAccessibility: { requested = true })
        addTeardownBlock { await controller.watchLoop?.stop() }

        await controller.startWatching()

        XCTAssertTrue(controller.isWatching, "the start must still happen")
        XCTAssertFalse(requested, "a remote start must not prompt for Accessibility")
    }

    /// `.toggle` resolving to a start goes through `startWatching`, so it
    /// inherits the same rule.
    func testRemoteToggleToStartDoesNotRequestAccessibility() async {
        var requested = false
        // swiftlint:disable:next trailing_closure
        let controller = makeController(requestAccessibility: { requested = true })
        addTeardownBlock { await controller.watchLoop?.stop() }

        await controller.applyWatchAction(.toggle)

        XCTAssertTrue(controller.isWatching)
        XCTAssertFalse(requested, "a remote toggle must not prompt for Accessibility")
    }

    /// The whole point of `startWatching` over `toggleWatching`: it awaits the
    /// private in-flight `startTask`, so a caller reporting state back — the
    /// `/v1/watch` route — sees the settled loop rather than a snapshot taken
    /// while mic access was still pending.
    func testStartWatchingAwaitsSettledState() async {
        let controller = makeController()
        addTeardownBlock { await controller.watchLoop?.stop() }

        let outcome = await controller.startWatching()

        XCTAssertEqual(outcome, .changed)
        // No `waitFor`: if the await didn't settle, this is nil right here.
        XCTAssertNotNil(controller.watchLoop, "startWatching must not return before the loop exists")
        XCTAssertTrue(controller.isWatching)
    }

    /// Idempotence is what makes a physical key correct: pressing "start" on an
    /// already-watching app is a satisfied request, not an error and not a flip.
    func testStartWatchingWhileWatchingIsUnchanged() async {
        let controller = makeController()
        addTeardownBlock { await controller.watchLoop?.stop() }
        await controller.startWatching()

        let outcome = await controller.startWatching()

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(controller.isWatching, "an idempotent start must not toggle watching off")
    }

    func testStopWatchingStopsAndIsThenUnchanged() async {
        let controller = makeController()
        addTeardownBlock { await controller.watchLoop?.stop() }
        await controller.startWatching()

        let first = await controller.stopWatching()
        let second = await controller.stopWatching()

        XCTAssertEqual(first, .changed)
        XCTAssertEqual(second, .unchanged)
        XCTAssertFalse(controller.isWatching)
    }

    /// A stop issued during the mic-access window must not land before the loop
    /// exists — otherwise it reports "already stopped" and the start completes
    /// right after it, leaving the app watching against the caller's request.
    func testStopWatchingDuringInFlightStartStillStops() async {
        let micGate = AsyncGate()
        // Not trailing-closure: a trailing closure binds to `makeDetector`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            await micGate.wait()
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching() // start, parked on the mic gate
        // Order the race for real. The gate controls when the start *unparks*,
        // not when the stop arrives, and only the latter decides the outcome:
        // without this the child task can be scheduled late enough to land past
        // the start's whole post-gate continuation, and the test passes even
        // with the join deleted from `stopWatching`.
        await waitFor { await micGate.hasWaiter }
        async let stopping = controller.stopWatching()
        await micGate.open()
        let stopped = await stopping

        XCTAssertEqual(stopped, .changed)
        XCTAssertFalse(controller.isWatching, "the stop must win over the start it was racing")
    }

    func testApplyWatchActionTogglesBothWays() async {
        let controller = makeController()
        addTeardownBlock { await controller.watchLoop?.stop() }

        let on = await controller.applyWatchAction(.toggle)
        XCTAssertEqual(on, .changed)
        XCTAssertTrue(controller.isWatching)

        let off = await controller.applyWatchAction(.toggle)
        XCTAssertEqual(off, .changed)
        XCTAssertFalse(controller.isWatching)
    }

    /// `toggleWatching` silently refuses while a manual recording owns the loop.
    /// Across an API that silence would read as success, so `startWatching`
    /// reports `.blocked` and the route turns it into a 409.
    func testStartIsBlockedDuringManualRecording() async throws {
        let controller = makeController()
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        let started = await controller.startWatching()

        XCTAssertEqual(started, .blocked)
        XCTAssertEqual(controller.watchLoop?.isManualRecording, true, "control must not disturb a manual recording")
    }

    /// `stop` is the asymmetric case: `isWatching` is false by definition while
    /// a manual recording owns the loop, so the requested end state already
    /// holds and there is nothing to refuse. The response body still carries
    /// `manualRecording: true`, so a controller that wants to know can see it
    /// without the request being reported as a conflict it is not.
    func testStopDuringManualRecordingIsUnchangedNotBlocked() async throws {
        let controller = makeController()
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        let stopped = await controller.stopWatching()

        XCTAssertEqual(stopped, .unchanged)
        XCTAssertEqual(controller.watchLoop?.isManualRecording, true, "a stop must not disturb a manual recording")
    }

    /// A start parked on an unanswered microphone dialog must not hold the HTTP
    /// handler and its connection open for as long as the prompt is up. The join
    /// gives up and reports `.failed`, which the route turns into a 503.
    ///
    /// Also pins that giving up actually returns: an earlier revision raced the
    /// join against a sleep in a task group, which deadlocked, because
    /// `Task.value` ignores cancellation and a group awaits every child before
    /// returning.
    func testStartWatchingGivesUpWhenTheStartNeverSettles() async {
        let micGate = AsyncGate()
        let controller = makeController(
            ensureMicAccess: {
                await micGate.wait()
                return true
            },
            startJoinTimeout: .milliseconds(50),
        )
        addTeardownBlock {
            await micGate.open()
            await controller.watchLoop?.stop()
        }

        let outcome = await controller.startWatching()

        XCTAssertEqual(outcome, .failed, "an unsettled start must not hold the caller")
    }

    /// `startManualRecording` assigns `watchLoop` only after the mic gate, so
    /// reading the loop alone reports "no manual recording" for that whole
    /// window. A remote start landing in it used to build an auto loop that the
    /// manual task then overwrote without stopping, orphaning a live loop that
    /// nothing could cancel.
    func testStartIsBlockedWhileManualStartIsStillInFlight() async {
        let micGate = AsyncGate()
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            await micGate.wait()
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
        await waitFor { await micGate.hasWaiter }

        let started = await controller.startWatching()

        XCTAssertEqual(started, .blocked, "an in-flight manual start must block a remote start")
        await micGate.open()
    }
}

/// Hands out call indices so one injected seam can park different callers on
/// different gates. Sharing a single gate leaves the resume order undefined.
/// Lets a seam injected at construction call back into the controller it is
/// wired to, which does not exist yet when the seam is built.
@MainActor
private final class ControllerBox {
    var controller: WatchingController?
}

private actor CallCounter {
    private var count = 0

    func next() -> Int {
        defer { count += 1 }
        return count
    }
}
