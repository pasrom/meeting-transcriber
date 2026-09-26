import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The wiring between a recording that `WatchingController` starts and the
/// capture-fault notification, driven through the controller's own start paths
/// rather than through `ChannelHealthController.applyTick`.
///
/// `ChannelFaultIntegrationTests` proves the controller reports a microphone
/// that delivers nothing once it is ticked. What it cannot show is that
/// anything ticks it: the polling task only exists if the `.recording`
/// transition reaches `ChannelHealthController.start` with a source, it has to
/// find the loop's recorder, and it has to keep ticking until the window has
/// passed. A microphone that never delivered a buffer was not seen to be
/// reported in the field, so both start paths are pinned here with the real
/// polling task.
///
/// The window is small but positive on purpose. With a zero window the first
/// tick decides, and a polling task that ticks once and stops, or one that
/// restarts its clock on every tick, passes exactly like a working one.
///
/// Where this ends: at the `AppNotifying` call. Whether the system then shows
/// the notification is outside what these tests can see.
@MainActor
final class WatchingControllerChannelFaultTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    private let window: TimeInterval = 0.3

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerChannelFaultTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// Stamps the moment the recording's capture started, which is the
    /// earliest the monitor's clock can begin: the first tick that counts is
    /// one that found this recorder, and the loop publishes the recorder only
    /// after `start` returned.
    private final class StampingRecorder: MockRecorder {
        private(set) var startedAt: Date?

        override func start(source: RecordingSource, micDeviceUID: String?, debugLogging: Bool) {
            startedAt = Date()
            super.start(source: source, micDeviceUID: micDeviceUID, debugLogging: debugLogging)
        }
    }

    /// Records when each notification was handed over, which the shared
    /// `RecordingNotifier` has no reason to know.
    private final class StampingNotifier: AppNotifying {
        private(set) var calls: [(title: String, body: String, date: Date)] = []

        func notify(title: String, body: String, urgency _: NotificationUrgency) {
            calls.append((title: title, body: body, date: Date()))
        }
    }

    /// The body the user is shown for a microphone that delivers nothing. The
    /// title alone would not do: the app channel carries the same title.
    private let deadMicBody = ChannelHealthController.faultMessage(
        channel: .mic, fault: .noBuffers, everCarriedSignal: false,
    )

    /// A recorder whose microphone has never delivered a buffer, as in both
    /// field reports, while the app channel carries signal.
    private func makeRecorderWithDeadMic() -> StampingRecorder {
        let recorder = StampingRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
        recorder.micSignalAges = .unknown
        recorder.appSignalAges = .deliveringSignalNow
        return recorder
    }

    private func micFaultDate(_ notifier: StampingNotifier) -> Date? {
        notifier.calls.first { $0.title == "Capture Channel Silent" && $0.body == deadMicBody }?.date
    }

    /// The report arrives, and not before the window has run from `since`, the
    /// earliest moment the monitor's clock can have started, read once the
    /// report is in. A lower bound
    /// rather than a "nothing yet" check straight after `.recording`: that
    /// check races the first tick under a loaded parallel run, while this one
    /// holds however late the test gets to look.
    private func assertReportedAfterTheWindow(
        _ notifier: StampingNotifier,
        since: @autoclosure () -> Date?,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async throws {
        // The overload that sleeps between checks: the other one spins
        // `Task.yield()` on the main actor for the whole window.
        await waitFor({ self.micFaultDate(notifier) != nil }, timeout: .seconds(3))
        let reported = try XCTUnwrap(
            micFaultDate(notifier), "reported: \(notifier.calls.map(\.title))", file: file, line: line,
        )
        let started = try XCTUnwrap(since(), "precondition: the clock's earliest start is known", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            reported.timeIntervalSince(started), window,
            "reported before the window could have passed", file: file, line: line,
        )
    }

    /// Without record-only, although one field report ran in it: that setting
    /// is read only when the recording stops, so the monitoring path is the same
    /// either way, and turning it on here would make every stop try to move the
    /// double's mix file out of the shared temp directory.
    func testADeadMicrophoneInAnAutoDetectedRecordingIsReported() async throws {
        let notifier = StampingNotifier()
        let recorder = makeRecorderWithDeadMic()
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
            channelFaultWindow: window,
            makeDetector: { FixedMeetingDetector() },
            makeRecorder: { recorder },
        )
        let started = await controller.startWatching()
        // Registered before anything can fail: a failed assertion must not
        // leave the recording and its 10 Hz polling running into the next test.
        addTeardownBlock { _ = await controller.stopWatching() }
        XCTAssertEqual(started, .changed, "precondition")
        await waitFor(controller.watchLoop?.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(controller.watchLoop?.state, .recording, "precondition: the meeting must be recording by now")

        try await assertReportedAfterTheWindow(notifier, since: recorder.startedAt)
    }

    func testADeadMicrophoneInAManualAppRecordingIsReported() async throws {
        let notifier = StampingNotifier()
        let recorder = makeRecorderWithDeadMic()
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
            channelFaultWindow: window,
            // Labelled on purpose: as a trailing closure it would bind to the
            // first closure parameter, not to `makeRecorder`.
            // swiftlint:disable:next trailing_closure
            makeRecorder: { recorder },
        )

        // This process, so the target is alive: the loop ends a manual recording
        // as soon as its target process is gone, which with a made-up pid is
        // before the window has passed.
        controller.startManualRecording(pid: getpid(), appName: "Chrome", title: "Standup")
        // Never ends by itself with a live target, so it has to be stopped
        // even when an assertion below fails.
        addTeardownBlock { controller.stopManualRecording() }
        await waitFor(controller.watchLoop?.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(controller.watchLoop?.state, .recording, "precondition: the recording must have started")

        try await assertReportedAfterTheWindow(notifier, since: recorder.startedAt)
    }

    /// The polling task can start before a recorder exists: on the auto path
    /// `.recording` is set first and the recorder factory may suspend
    /// (attaching live-caption sinks). Ticks that find no recorder must be
    /// skipped, not end the task, and the window is measured from the first
    /// tick that did find one, which the lower bound checks: it is taken from
    /// the moment the provider first hands the recorder over, three ticks after
    /// `start`, so a clock started by `start` itself reports too early and
    /// fails. Driven on `ChannelHealthController.start`
    /// directly, because `WatchingController`'s `makeRecorder` seam is
    /// synchronous, so through it the recorder always exists by the first tick.
    func testMonitoringThatStartsBeforeTheRecorderExistsStillReports() async throws {
        let notifier = StampingNotifier()
        let controller = ChannelHealthController(
            notifier: notifier, debounceSeconds: { self.window }, indicatorEnabled: { false },
        )
        let recorder = makeRecorderWithDeadMic()
        var providerCalls = 0
        var firstServedAt: Date?
        controller.start(source: .forApp(pid: getpid(), noMic: false)) {
            providerCalls += 1
            // The first few ticks find nothing, as while the factory is suspended.
            guard providerCalls > 3 else { return nil }
            if firstServedAt == nil { firstServedAt = Date() }
            return recorder
        }
        addTeardownBlock { controller.stop() }

        try await assertReportedAfterTheWindow(notifier, since: firstServedAt)
        XCTAssertGreaterThan(providerCalls, 3, "precondition: the recorder was absent for the first ticks")
    }
}
