@testable import MeetingTranscriber
import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    // MARK: - Helpers

    /// Yields repeatedly until `condition()` is true or the timeout elapses.
    /// Needed for tests that await toggleWatching()/startManualRecording() which
    /// internally spawn a Task containing AVCaptureDevice.requestAccess — a real
    /// async suspension point that requires more than one yield to resolve.
    private func waitFor(
        _ condition: @autoclosure () -> Bool,
        timeout: Duration = .milliseconds(500),
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    private func makeState() -> (AppState, RecordingNotifier) {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        return (state, notifier)
    }

    /// AppState whose pipelineQueue writes to a temp dir (no real filesystem side effects).
    private func makeIsolatedState(logDir: URL) -> (AppState, RecordingNotifier) {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.pipelineQueue = PipelineQueue(logDir: logDir)
        return (state, notifier)
    }

    private func makeJob(title: String = "Sprint Review") -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "TestApp",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }

    // MARK: - Default State

    func testIsWatchingFalseWhenNoWatchLoop() {
        let (state, _) = makeState()
        XCTAssertFalse(state.isWatching)
    }

    func testCurrentStateLabelIdleByDefault() {
        let (state, _) = makeState()
        XCTAssertEqual(state.currentStateLabel, "Idle")
    }

    func testCurrentBadgeInactiveByDefault() {
        let (state, _) = makeState()
        XCTAssertEqual(state.currentBadge, .inactive)
    }

    func testCurrentStatusNilWhenNoWatchLoop() {
        let (state, _) = makeState()
        XCTAssertNil(state.currentStatus)
    }

    // MARK: - isWatching

    func testIsWatchingTrueWhenLoopActiveNotManual() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertTrue(state.isWatching)
    }

    func testIsWatchingFalseWhenLoopNotStarted() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        // loop not started → isActive == false
        XCTAssertFalse(state.isWatching)
    }

    func testIsWatchingFalseWhenManualRecording() throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertFalse(state.isWatching)
    }

    // MARK: - currentStateLabel

    func testCurrentStateLabelWatchingWhenLoopActive() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertEqual(state.currentStateLabel, "Watching for Meetings...")
    }

    func testCurrentStateLabelRecordingWhenManualRecording() throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertEqual(state.currentStateLabel, "Recording")
    }

    func testCurrentStateLabelIdleWhenLoopStopped() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        loop.start()
        loop.stop()
        state.watchLoop = nil
        XCTAssertEqual(state.currentStateLabel, "Idle")
    }

    // MARK: - currentStatus

    func testCurrentStatusNilWhenLoopNotStarted() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        XCTAssertNil(state.currentStatus)
    }

    func testCurrentStatusNotNilWhenLoopActive() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertNotNil(state.currentStatus)
    }

    func testCurrentStatusStateMatchesLoopTranscriberState() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertEqual(state.currentStatus?.state, .watching)
    }

    func testCurrentStatusDetailMatchesLoopDetail() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertEqual(state.currentStatus?.detail, "Polling for meetings...")
    }

    func testCurrentStatusMeetingNilWhenNoActiveMeeting() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertNil(state.currentStatus?.meeting)
    }

    func testCurrentStatusMeetingFromManualRecordingInfo() throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
        defer { loop.stop() }
        let status = try XCTUnwrap(state.currentStatus)
        XCTAssertEqual(status.meeting?.app, "Chrome")
        XCTAssertEqual(status.meeting?.title, "Standup")
        XCTAssertEqual(status.meeting?.pid, 42)
    }

    // MARK: - currentBadge integration

    func testCurrentBadgeUpdateAvailableWithNoActivity() throws {
        let (state, _) = makeState()
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        state.updateChecker.availableUpdate = ReleaseInfo(
            tagName: "v9.9.9",
            name: "Test Release",
            prerelease: false,
            htmlURL: url,
            dmgURL: nil,
        )
        XCTAssertEqual(state.currentBadge, .updateAvailable)
    }

    func testCurrentBadgeRecordingWhenLoopRecording() throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertEqual(state.currentBadge, .recording)
    }

    // MARK: - toggleWatching: stop path

    func testToggleWatchingStopsActiveLoop() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        loop.start()
        state.watchLoop = loop
        XCTAssertTrue(state.isWatching)

        state.toggleWatching()

        XCTAssertNil(state.watchLoop)
        XCTAssertFalse(state.isWatching)
    }

    func testToggleWatchingWhileManualRecordingIsNoOp() throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        state.toggleWatching() // must be a no-op

        XCTAssertNotNil(state.watchLoop)
        XCTAssertEqual(state.watchLoop?.isManualRecording, true)
    }

    // MARK: - toggleWatching: start path (async)

    // toggleWatching() spawns a Task { @MainActor }. We yield once to let it run.
    // In CI, Permissions.ensureMicrophoneAccess() returns false immediately (no bundle),
    // but toggleWatching() ignores the return value so WatchLoop is always created.

    func testToggleWatchingCreatesWatchLoop() async {
        let (state, _) = makeState()
        addTeardownBlock { state.watchLoop?.stop() }

        state.toggleWatching()
        await waitFor(state.watchLoop != nil)

        XCTAssertNotNil(state.watchLoop)
    }

    func testToggleWatchingMakesLoopActive() async {
        let (state, _) = makeState()
        addTeardownBlock { state.watchLoop?.stop() }

        state.toggleWatching()
        await waitFor(state.watchLoop?.isActive == true)

        XCTAssertEqual(state.watchLoop?.isActive, true)
    }

    // MARK: - stopManualRecording

    func testStopManualRecordingClearsWatchLoop() throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")

        state.stopManualRecording()

        XCTAssertNil(state.watchLoop)
    }

    func testStopManualRecordingWhenNoLoopIsNoOp() {
        let (state, _) = makeState()
        state.stopManualRecording() // must not crash
        XCTAssertNil(state.watchLoop)
    }

    // MARK: - enqueueFiles

    func testEnqueueFilesSingleURL() {
        let (state, _) = makeState()
        let url = URL(fileURLWithPath: "/tmp/sprint-review.wav")

        state.enqueueFiles([url])

        XCTAssertEqual(state.pipelineQueue.jobs.count, 1)
    }

    func testEnqueueFilesMultipleURLs() {
        let (state, _) = makeState()
        let urls = (1 ... 3).map { URL(fileURLWithPath: "/tmp/meeting-\($0).wav") }

        state.enqueueFiles(urls)

        XCTAssertEqual(state.pipelineQueue.jobs.count, 3)
    }

    func testEnqueueFilesTitleFromLastPathComponent() {
        let (state, _) = makeState()
        let url = URL(fileURLWithPath: "/tmp/sprint-review.wav")

        state.enqueueFiles([url])

        XCTAssertEqual(state.pipelineQueue.jobs[0].meetingTitle, "sprint-review")
    }

    func testEnqueueFilesAppNameIsFile() {
        let (state, _) = makeState()
        state.enqueueFiles([URL(fileURLWithPath: "/tmp/meeting.wav")])
        XCTAssertEqual(state.pipelineQueue.jobs[0].appName, "File")
    }

    func testEnqueueFilesEmptyArrayIsNoOp() {
        let (state, _) = makeState()
        state.enqueueFiles([])
        XCTAssertTrue(state.pipelineQueue.jobs.isEmpty)
    }

    func testEnqueueFilesCreatesJobsWithNilAudioPaths() {
        let (state, _) = makeState()
        state.enqueueFiles([URL(fileURLWithPath: "/tmp/meeting.wav")])
        XCTAssertNil(state.pipelineQueue.jobs[0].appPath)
        XCTAssertNil(state.pipelineQueue.jobs[0].micPath)
    }

    // MARK: - ensurePipelineQueue

    func testEnsurePipelineQueueReplacesBareQueue() {
        let (state, _) = makeState()
        XCTAssertNil(state.pipelineQueue.whisperKit, "Precondition: fresh queue has no whisperKit")

        state.ensurePipelineQueue()

        XCTAssertNotNil(state.pipelineQueue.whisperKit)
    }

    func testEnsurePipelineQueueIdempotent() {
        let (state, _) = makeState()
        state.ensurePipelineQueue()
        let firstID = ObjectIdentifier(state.pipelineQueue)

        state.ensurePipelineQueue()

        XCTAssertEqual(ObjectIdentifier(state.pipelineQueue), firstID)
    }

    // MARK: - makePipelineQueue

    func testMakePipelineQueueHasWhisperKit() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.makePipelineQueue().whisperKit)
    }

    func testMakePipelineQueueHasDiarizationFactory() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.makePipelineQueue().diarizationFactory)
    }

    func testMakePipelineQueueHasProtocolGeneratorFactory() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.makePipelineQueue().protocolGeneratorFactory)
    }

    func testMakePipelineQueueSetsOutputDir() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.makePipelineQueue().outputDir)
    }

    // MARK: - makeProtocolGenerator

    func testMakeProtocolGeneratorOpenAI() {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let state = AppState(settings: settings)
        XCTAssertTrue(state.makeProtocolGenerator() is OpenAIProtocolGenerator)
    }

    #if !APPSTORE
        func testMakeProtocolGeneratorClaudeCLI() {
            let settings = AppSettings()
            settings.protocolProvider = .claudeCLI
            let state = AppState(settings: settings)
            XCTAssertTrue(state.makeProtocolGenerator() is ClaudeCLIProtocolGenerator)
        }
    #endif

    // MARK: - configurePipelineCallbacks

    func testConfigurePipelineCallbacksDoneFiresNotification() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appstate_callbacks_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let (state, notifier) = makeIsolatedState(logDir: tmpDir)
        state.configurePipelineCallbacks()

        let job = makeJob(title: "Sprint Review")
        state.pipelineQueue.onJobStateChange?(job, .transcribing, .done)

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Protocol Ready")
        XCTAssertEqual(notifier.calls[0].body, "Sprint Review")
    }

    func testConfigurePipelineCallbacksErrorFiresNotification() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appstate_callbacks_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let (state, notifier) = makeIsolatedState(logDir: tmpDir)
        state.configurePipelineCallbacks()

        var job = makeJob()
        job = PipelineJob(
            meetingTitle: job.meetingTitle,
            appName: job.appName,
            mixPath: job.mixPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        // Simulate a job with an error string
        let errorJob = jobWithError(job, message: "Transcription failed")
        state.pipelineQueue.onJobStateChange?(errorJob, .transcribing, .error)

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Error")
        XCTAssertEqual(notifier.calls[0].body, "Transcription failed")
    }

    func testConfigurePipelineCallbacksTranscribingNoNotification() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appstate_callbacks_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let (state, notifier) = makeIsolatedState(logDir: tmpDir)
        state.configurePipelineCallbacks()

        state.pipelineQueue.onJobStateChange?(makeJob(), .waiting, .transcribing)

        XCTAssertTrue(notifier.calls.isEmpty)
    }

    // MARK: - startManualRecording (async, environment-sensitive)

    // DualSourceRecorder.start() requires real audio hardware — will throw in CI.
    // AppState catches the error and fires notify("Error", ...) / sets watchLoop = nil.
    // Both paths fire exactly one notification, so we assert on that.

    func testStartManualRecordingSendsNotification() async {
        let (state, notifier) = makeState()
        addTeardownBlock { state.watchLoop?.stop() }

        state.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        // Success → "Manual Recording" / hardware unavailable → "Error"
        await waitFor(!notifier.calls.isEmpty)

        XCTAssertTrue(
            notifier.calls.contains { $0.title == "Manual Recording" || $0.title == "Error" },
            "Expected a notification but got none. calls: \(notifier.calls)",
        )
    }

    func testStartManualRecordingStopsExistingAutoWatchLoop() async {
        let (state, _) = makeState()
        let (existingLoop, _) = makeTestWatchLoop()
        existingLoop.start()
        state.watchLoop = existingLoop
        XCTAssertTrue(existingLoop.isActive)

        state.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(!existingLoop.isActive)

        XCTAssertFalse(existingLoop.isActive, "Existing auto-watch loop should be stopped")
    }
}

// MARK: - Private helpers

/// Returns a copy of `job` with the error field set via updateJobState simulation.
/// Since PipelineJob is a struct and error is set by PipelineQueue internally,
/// we construct a new job and set the error via the queue's updateJobState.
@MainActor
private func jobWithError(_ job: PipelineJob, message: String) -> PipelineJob {
    // PipelineJob.error is var but directly settable since it's internal
    var copy = job
    copy.error = message
    return copy
}
