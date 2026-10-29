@testable import MeetingTranscriber

// swiftlint:disable file_length
import ViewInspector
import XCTest

@MainActor
// swiftlint:disable:next attributes type_body_length
final class MenuBarViewTests: XCTestCase {
    // MARK: - Helpers

    private func makeStatus(
        state: TranscriberState = .idle,
        detail: String = "",
        meeting: MeetingInfo? = nil,
        protocolPath: String? = nil,
        error: String? = nil,
    ) -> TranscriberStatus {
        TranscriberStatus(
            version: 1,
            timestamp: "2024-01-01T00:00:00",
            state: state,
            detail: detail,
            meeting: meeting,
            protocolPath: protocolPath,
            error: error,
            audioPath: nil,
            pid: nil,
        )
    }

    private func makeView(
        status: TranscriberStatus? = nil,
        isWatching: Bool = false,
        pipelineQueue: PipelineQueue? = nil,
        updateChecker: UpdateChecker? = nil,
        onNameSpeakers: (() -> Void)? = nil,
        onStopManualRecording: (() -> Void)? = nil,
        onRecordMicrophone: @escaping () -> Void = {},
        noMic: Bool = false,
        manualRecordingPendingOrActive: Bool = false,
    ) throws -> MenuBarView {
        try MenuBarView(
            status: status,
            isWatching: isWatching,
            pipelineQueue: pipelineQueue ?? makeIsolatedQueue(),
            updateChecker: updateChecker,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: onRecordMicrophone,
            noMic: noMic,
            manualRecordingPendingOrActive: manualRecordingPendingOrActive,
            onStopManualRecording: onStopManualRecording,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: onNameSpeakers,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
    }

    // MARK: - Start/Stop button

    func testIdleShowsStartWatching() throws {
        let sut = try makeView(status: makeStatus(state: .idle), isWatching: false)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Start Watching"))
    }

    func testWatchingShowsStopWatching() throws {
        let sut = try makeView(status: makeStatus(state: .watching), isWatching: true)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Watching"))
    }

    // MARK: - Meeting info

    func testMeetingInfoShownWhenRecording() throws {
        let meeting = MeetingInfo(app: "Teams", title: "Standup", pid: 123)
        let sut = try makeView(status: makeStatus(state: .recording, meeting: meeting))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Standup"))
    }

    func testMeetingInfoHiddenWhenIdle() throws {
        let sut = try makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Standup"))
    }

    // MARK: - Error display

    func testErrorShownWhenErrorState() throws {
        let sut = try makeView(status: makeStatus(state: .error, error: "Python crashed"))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Python crashed"))
    }

    func testErrorHiddenWhenNotErrorState() throws {
        let sut = try makeView(status: makeStatus(state: .recording, error: "stale error"))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "stale error"))
    }

    // MARK: - Name Speakers button

    func testNameSpeakersButtonShownWhenWaiting() throws {
        // swiftlint:disable:next trailing_closure
        let sut = try makeView(status: makeStatus(state: .waitingForSpeakerNames), onNameSpeakers: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Name Speakers..."))
    }

    func testNameSpeakersButtonHiddenWhenIdle() throws {
        let sut = try makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Name Speakers..."))
    }

    // MARK: - Detail text

    func testDetailShownWhenNonEmpty() throws {
        let sut = try makeView(status: makeStatus(state: .watching, detail: "Checking Teams..."))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Checking Teams..."))
    }

    func testDetailHiddenWhenEmpty() throws {
        let sut = try makeView(status: makeStatus(state: .watching, detail: ""))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Checking Teams..."))
    }

    // MARK: - Protocol link

    func testOpenLastProtocolShownWhenPathPresent() throws {
        let sut = try makeView(status: makeStatus(state: .protocolReady, protocolPath: "/tmp/p.md"))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Open Last Protocol"))
    }

    func testOpenLastProtocolHiddenWhenNoPath() throws {
        let sut = try makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Open Last Protocol"))
    }

    // MARK: - Static buttons always present

    func testSettingsButtonExists() throws {
        let sut = try makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Settings..."))
    }

    func testOpenProtocolsFolderButtonExists() throws {
        let sut = try makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Open Protocols Folder"))
    }

    func testQuitButtonExists() throws {
        let sut = try makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Quit"))
    }

    // MARK: - Record Microphone (issue #633)

    func testRecordMicrophoneButtonShownWhenIdle() throws {
        let sut = try makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Record Microphone"))
    }

    func testRecordMicrophoneButtonCallsCallback() throws {
        var called = false
        // swiftlint:disable:next trailing_closure
        let sut = try makeView(status: makeStatus(state: .idle), onRecordMicrophone: { called = true })

        try sut.inspect().find(button: "Record Microphone").tap()

        XCTAssertTrue(called)
    }

    func testRecordMicrophoneButtonHiddenWhileRecording() throws {
        // Same rule as Record App...: the menu offers Stop Recording instead.
        let sut = try makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(button: "Record Microphone"))
    }

    func testRecordMicrophoneButtonDisabledWhenNoMicIsSet() throws {
        // Visible but dead, on purpose: someone who set "No Microphone" months
        // ago needs to see the entry to learn why it cannot run, and starting
        // anyway would record nothing.
        let sut = try makeView(status: makeStatus(state: .idle), noMic: true)

        let button = try sut.inspect().find(button: "Record Microphone")
        XCTAssertTrue(button.isDisabled())
    }

    func testRecordMicrophoneButtonDisabledWhileAManualStartIsStillInFlight() throws {
        // The window between registering a start and the loop existing. The
        // narrow `state == .recording` predicate misses it, leaving the item
        // enabled and the click silently dropped by the ownership guard.
        let sut = try makeView(status: makeStatus(state: .idle), manualRecordingPendingOrActive: true)

        let button = try sut.inspect().find(button: "Record Microphone")
        XCTAssertTrue(button.isDisabled())
    }

    func testRecordMicrophoneButtonEnabledWhenTheMicrophoneIsAllowed() throws {
        // Control for the assertion above: without it a button that was always
        // disabled would pass just as well.
        let sut = try makeView(status: makeStatus(state: .idle), noMic: false)

        let button = try sut.inspect().find(button: "Record Microphone")
        XCTAssertFalse(button.isDisabled())
    }

    // MARK: - Button tap callbacks

    func testStartStopButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: { called = true },
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Start Watching").tap()
        XCTAssertTrue(called)
    }

    func testQuitButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: { called = true },
        )
        let body = try sut.inspect()
        try body.find(button: "Quit").tap()
        XCTAssertTrue(called)
    }

    func testSettingsButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: { called = true },
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Settings...").tap()
        XCTAssertTrue(called)
    }

    func testProtocolsFolderButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: { called = true },
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Open Protocols Folder").tap()
        XCTAssertTrue(called)
    }

    func testOpenLastProtocolButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .protocolReady, protocolPath: "/tmp/p.md"),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: { called = true },
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Open Last Protocol").tap()
        XCTAssertTrue(called)
    }

    func testNameSpeakersButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .waitingForSpeakerNames),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: { called = true },
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Name Speakers...").tap()
        XCTAssertTrue(called)
    }

    // MARK: - State label

    func testNilStatusShowsIdleLabel() throws {
        let sut = try makeView(status: nil)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Idle"))
    }

    func testMeetingAppAndPidShown() throws {
        let meeting = MeetingInfo(app: "Zoom", title: "Retro", pid: 456)
        let sut = try makeView(status: makeStatus(state: .recording, meeting: meeting))
        let body = try sut.inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("Zoom") == true }
        XCTAssertTrue(found, "App name 'Zoom' should appear in meeting info")
    }

    // MARK: - Processing section

    func testProcessingSectionHiddenWhenNoJobs() throws {
        let sut = try makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Processing"))
    }

    func testProcessingSectionShownWithActiveJob() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .transcribing)

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Processing"))
        XCTAssertNoThrow(try body.find(text: "Standup"))
        XCTAssertNoThrow(try body.find(text: "Transcribing... 0s"))
    }

    func testDismissButtonShownForCompletedJob() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Retro",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Dismiss"))
    }

    func testProcessFilesButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: { called = true },
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Process Audio/Video Files...").tap()
        XCTAssertTrue(called)
    }

    func testDismissButtonCallsCallbackWithJobID() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        var dismissedID: UUID?
        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { dismissedID = $0 },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Dismiss").tap()
        XCTAssertEqual(dismissedID, job.id)
    }

    func testDismissButtonShownForErrorJob() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Webex",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Failed")

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Dismiss"))
        XCTAssertNoThrow(try body.find(text: "Failed"))
    }

    /// Retry is the only way to run a failed job again without importing its
    /// audio by hand. The queue has its own logDir: the default one is the
    /// app's real data folder.
    ///
    /// Each row carries its own identifier, so the second row's button retries
    /// the second job and leaves the first alone.
    func testRetryButtonRequeuesTheJobOfItsOwnRow() throws {
        let dir = try makeTempDirectory(prefix: "menubar_retry_test")
        let queue = PipelineQueue(logDir: dir)
        let first = try queue.insertJobForTesting(mixPath: emptyFile("first_mix.wav", in: dir), state: .error, error: "Failed")
        let second = try queue.insertJobForTesting(mixPath: emptyFile("second_mix.wav", in: dir), state: .error, error: "Failed")

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.jobRetryButton(1))
            .button()
            .tap()

        XCTAssertEqual(queue.jobs.first { $0.id == second }?.state, .waiting, "Retry did not requeue its own row's job")
        XCTAssertEqual(queue.jobs.first { $0.id == first }?.state, .error, "Retry requeued another row's job")
    }

    /// The button follows the queue's own check rather than the job's state,
    /// so it is absent for a failed job the queue would refuse to retry. The
    /// full set of refusals is covered on the queue; this is the one case a
    /// button keyed on the state alone would get wrong.
    func testRetryButtonIsAbsentForAFailedJobTheQueueWouldRefuse() throws {
        let dir = try makeTempDirectory(prefix: "menubar_retry_absent_test")
        let queue = PipelineQueue(logDir: dir)
        let mixPath = try emptyFile("shared_mix.wav", in: dir)
        queue.insertJobForTesting(mixPath: mixPath, state: .transcribing)
        queue.insertJobForTesting(mixPath: mixPath, state: .error, error: "This recording is already being processed")

        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()

        XCTAssertThrowsError(
            try body.find(viewWithAccessibilityIdentifier: A11yID.jobRetryButton(1)),
            "Retry offered while another job is still transcribing the same recording",
        )
    }

    private func emptyFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func testWarningJobShowsWarningText() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        var warningJob = job
        warningJob.warnings.append("Diarization failed — speakers not identified")
        warningJob.state = .done
        queue.enqueue(warningJob)

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Diarization failed — speakers not identified"))
    }

    // MARK: - Record App button

    func testRecordAppButtonExistsWhenIdle() throws {
        let sut = try makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Record App..."))
    }

    func testRecordAppButtonHiddenDuringRecording() throws {
        let sut = try makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Record App..."))
    }

    func testRecordAppButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: { called = true },
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Record App...").tap()
        XCTAssertTrue(called)
    }

    // MARK: - Stop Recording button (manual)

    func testStopRecordingButtonVisibleDuringManualRecording() throws {
        // swiftlint:disable:next trailing_closure
        let sut = try makeView(status: makeStatus(state: .recording), onStopManualRecording: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingButtonHiddenWhenNoManualRecording() throws {
        let sut = try makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingButtonCallsCallback() throws {
        var called = false
        let sut = try MenuBarView(
            status: makeStatus(state: .recording),
            isWatching: false,
            pipelineQueue: makeIsolatedQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: { called = true },
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Stop Recording").tap()
        XCTAssertTrue(called)
    }

    // MARK: - Update indicator

    private func checkerWithUpdate(installedCask: String? = nil) throws -> UpdateChecker {
        let checker = UpdateChecker(provider: MockUpdateProvider(), installedCask: installedCask)
        checker.availableUpdate = try ReleaseInfo(
            tagName: "v1.0.0",
            name: "Release v1.0.0",
            prerelease: false,
            htmlURL: XCTUnwrap(URL(string: "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0")),
            dmgURL: URL(string: "https://example.com/app.dmg"),
        )
        return checker
    }

    func testUpdateIndicatorShownWhenUpdateAvailable() throws {
        let sut = try makeView(status: makeStatus(), updateChecker: checkerWithUpdate())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Update Available: v1.0.0"))
    }

    func testUpdateIndicatorSaysItCopiesBrewCommandForHomebrewInstall() throws {
        let sut = try makeView(
            status: makeStatus(),
            updateChecker: checkerWithUpdate(installedCask: "meeting-transcriber"),
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Update Available: v1.0.0 (Copy brew Command)"))
    }

    func testUpdateIndicatorHiddenWhenNoUpdate() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())

        let sut = try makeView(status: makeStatus(), updateChecker: checker)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Update Available:"))
    }

    func testUpdateIndicatorHiddenWhenNoChecker() throws {
        let sut = try makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Update Available:"))
    }

    // MARK: - Process Files button

    func testProcessFilesButtonAlwaysExists() throws {
        let sut = try makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Process Audio/Video Files..."))
    }

    // MARK: - Error job display

    func testErrorJobShowsErrorMessage() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Broken",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Transcription failed")

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Transcription failed"))
    }

    // MARK: - Record/Stop button mutual exclusion

    func testRecordAppAndStopBothHiddenDuringAutoRecording() throws {
        let sut = try makeView(status: makeStatus(state: .recording), onStopManualRecording: nil)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Record App..."))
        XCTAssertThrowsError(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingReplacesRecordAppButton() throws {
        // swiftlint:disable:next trailing_closure
        let sut = try makeView(status: makeStatus(state: .idle), onStopManualRecording: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Recording"))
        XCTAssertThrowsError(try body.find(text: "Record App..."))
    }

    // MARK: - Job state labels

    func testWaitingJobShowsWaitingLabel() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Waiting..."))
    }

    func testCancelButtonShownForWaitingJob() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Cancel"))
    }

    func testJobRowDoesNotContainSpacerOrHStack() throws {
        // This checks the SwiftUI structure; ViewInspector cannot verify native
        // NSMenu hit-testing or which row macOS highlights on hover.
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(ViewType.Spacer.self))
        XCTAssertThrowsError(try body.find(ViewType.HStack.self))
    }

    func testCompletedQueueShowsCompletedHeader() throws {
        let dir = try makeTempDirectory(prefix: "menubar_completed_test")
        let queue = PipelineQueue(logDir: dir)
        var job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        queue.insertJobForTesting(job)

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Completed"))
    }

    func testJobLabelsAndCancelArePresent() throws {
        let dir = try makeTempDirectory(prefix: "menubar_job_label_test")
        let queue = PipelineQueue(logDir: dir)
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)

        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()
        XCTAssertNoThrow(try body.find(text: "Sprint"))
        XCTAssertNoThrow(try body.find(text: "Waiting..."))
        XCTAssertFalse(try body.find(button: "Cancel").isDisabled())
    }

    /// Every job is a run of flat menu items, so the only thing that tells one
    /// job's Cancel / Retry / Dismiss from the next is the separator between them.
    func testJobsAreSeparatedByADivider() throws {
        let dir = try makeTempDirectory(prefix: "menubar_job_divider_test")
        let queue = PipelineQueue(logDir: dir)
        func dividerCount() throws -> Int {
            try makeView(status: makeStatus(), pipelineQueue: queue).inspect()
                .findAll(ViewType.Divider.self).count
        }
        let first = try PipelineJob(
            meetingTitle: "First", appName: "Teams",
            mixPath: emptyFile("first_mix.wav", in: dir),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(first)
        let withOneJob = try dividerCount()

        let second = try PipelineJob(
            meetingTitle: "Second", appName: "Zoom",
            mixPath: emptyFile("second_mix.wav", in: dir),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(second)

        XCTAssertEqual(try dividerCount(), withOneJob + 1)
    }

    func testCancelButtonCancelsOnlyItsOwnJob() throws {
        let dir = try makeTempDirectory(prefix: "menubar_cancel_test")
        let queue = PipelineQueue(logDir: dir)
        let first = try PipelineJob(
            meetingTitle: "First", appName: "Teams",
            mixPath: emptyFile("first_mix.wav", in: dir),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let second = try PipelineJob(
            meetingTitle: "Second", appName: "Zoom",
            mixPath: emptyFile("second_mix.wav", in: dir),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(first)
        queue.enqueue(second)

        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()
        let cancelButtons = body.findAll(ViewType.Button.self).filter { button in
            (try? button.labelView().text().string()) == "Cancel"
        }
        XCTAssertEqual(cancelButtons.count, 2)
        try cancelButtons[1].tap()

        XCTAssertTrue(queue.jobs.contains { $0.id == first.id })
        XCTAssertFalse(queue.jobs.contains { $0.id == second.id })
    }

    func testActiveJobProgressLabelRendersTiming() throws {
        let dir = try makeTempDirectory(prefix: "menu_active_progress_test")
        let queue = PipelineQueue(logDir: dir)
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .transcribing)

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Cancel"))
        XCTAssertNoThrow(try body.find(text: "Sprint"))
        // Prefix, not the exact seconds: a loaded runner can take a second
        // between `updateJobState` and `inspect()`.
        XCTAssertNoThrow(try body.find(ViewType.Text.self) { try $0.string().hasPrefix("Transcribing... ") })
    }

    func testCancelButtonHiddenForDoneJob() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(button: "Cancel"))
    }

    func testDoneJobWithoutPathsHidesOpenButton() throws {
        let queue = try makeIsolatedQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let sut = try makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(button: "Open"))
    }

    // MARK: - All state labels shown

    func testAllTranscriberStateLabelsRendered() throws {
        let states: [TranscriberState] = [
            .idle, .watching, .recording, .transcribing,
            .generatingProtocol, .protocolReady, .error,
        ]
        for state in states {
            let sut = try makeView(status: makeStatus(state: state))
            let body = try sut.inspect()
            XCTAssertNoThrow(
                try body.find(text: state.label),
                "State label '\(state.label)' not found for \(state)",
            )
        }
    }

    // MARK: - Multiple jobs

    func testMultipleJobsRendered() throws {
        let queue = try makeIsolatedQueue()
        let job1 = PipelineJob(
            meetingTitle: "Meeting 1",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix1.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let job2 = PipelineJob(
            meetingTitle: "Meeting 2",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix2.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job1)
        queue.enqueue(job2)

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Meeting 1"))
        XCTAssertNoThrow(try body.find(text: "Meeting 2"))
    }
}
