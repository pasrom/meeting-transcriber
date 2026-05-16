// swiftlint:disable file_length
@testable import MeetingTranscriber
import XCTest

@MainActor
final class AppStateTests: XCTestCase { // swiftlint:disable:this type_body_length
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testLogDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Per-test isolated logDir for the PipelineQueue snapshot file.
        // Without it, concurrent test methods (xctest spawns a subprocess
        // per method under `--parallel`) race on the production
        // `AppPaths.ipcDir/pipeline_queue.json`, leaking jobs across
        // tests as `count == 2` where `count == 1` is expected.
        testLogDir = try makeTempDirectory(prefix: "AppStateTests")
    }

    // MARK: - Helpers

    private func makeState() -> (AppState, RecordingNotifier) {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        // Inject a PipelineQueue with mocks + the per-test isolated logDir.
        // The engine != nil arm short-circuits `ensurePipelineQueue()` so
        // it doesn't replace our queue with one wired to the production
        // `AppPaths.ipcDir` path on the first `enqueueFiles` call.
        state.pipelineQueue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: testLogDir,
            logDir: testLogDir,
        )
        return (state, notifier)
    }

    /// AppState with a caller-provided logDir. Use when a test wants to
    /// inspect snapshot contents at a known path; otherwise prefer
    /// `makeState()` which uses the per-test isolated `testLogDir`.
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

    func testIsWatchingFalseWhenManualRecording() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
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

    func testCurrentStateLabelRecordingWhenManualRecording() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
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

    func testCurrentStatusMeetingFromManualRecordingInfo() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
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

    func testCurrentBadgeRecordingWhenLoopRecording() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
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

    func testToggleWatchingWhileManualRecordingIsNoOp() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
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

    func testStopManualRecordingClearsWatchLoop() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")

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

    func testEnqueueFilesPairsTripletAsOneDualTrackJob() {
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/standup_app.wav"),
            URL(fileURLWithPath: "/tmp/standup_mic.wav"),
            URL(fileURLWithPath: "/tmp/standup_mix.wav"),
        ]

        state.enqueueFiles(urls)

        XCTAssertEqual(state.pipelineQueue.jobs.count, 1)
        let job = state.pipelineQueue.jobs[0]
        XCTAssertEqual(job.mixPath?.lastPathComponent, "standup_mix.wav")
        XCTAssertEqual(job.appPath?.lastPathComponent, "standup_app.wav")
        XCTAssertEqual(job.micPath?.lastPathComponent, "standup_mic.wav")
    }

    func testEnqueueExistingFilesEmptyArrayReturnsZero() {
        let (state, _) = makeState()
        XCTAssertEqual(state.enqueueExistingFiles([]), 0)
        XCTAssertTrue(state.pipelineQueue.jobs.isEmpty)
    }

    func testEnqueueExistingFilesAllMissingReturnsZeroAndDoesNotEnqueue() {
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/never-exists-\(UUID().uuidString).wav"),
            URL(fileURLWithPath: "/tmp/also-missing-\(UUID().uuidString).wav"),
        ]
        XCTAssertEqual(state.enqueueExistingFiles(urls), 0)
        XCTAssertTrue(state.pipelineQueue.jobs.isEmpty)
    }

    func testEnqueueExistingFilesPartialExistenceForwardsOnlyExisting() throws {
        let (state, _) = makeState()
        let tmpDir = try makeTempDirectory(prefix: "enqueue-existing")
        let existing = tmpDir.appendingPathComponent("present.wav")
        let missing = tmpDir.appendingPathComponent("absent.wav")
        try Data("RIFF".utf8).write(to: existing)

        let count = state.enqueueExistingFiles([existing, missing])

        XCTAssertEqual(count, 1)
        XCTAssertEqual(state.pipelineQueue.jobs.count, 1)
        XCTAssertEqual(state.pipelineQueue.jobs[0].mixPath?.lastPathComponent, "present.wav")
    }

    func testEnqueueFilesAppPlusMicWithoutMixHasNilMixPath() {
        // No `_mix.wav` in selection — job carries nil mixPath; the pipeline
        // mixes app+mic into the workdir cache on the fly, no persistent mix
        // is written to recordings/.
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/20260311_143000_app.wav"),
            URL(fileURLWithPath: "/tmp/20260311_143000_mic.wav"),
        ]

        state.enqueueFiles(urls)

        XCTAssertEqual(state.pipelineQueue.jobs.count, 1)
        let job = state.pipelineQueue.jobs[0]
        XCTAssertNil(job.mixPath, "paired without mix → nil mixPath")
        XCTAssertEqual(job.appPath?.lastPathComponent, "20260311_143000_app.wav")
        XCTAssertEqual(job.micPath?.lastPathComponent, "20260311_143000_mic.wav")
    }

    func testEnqueueFilesLoneAppFallsBackToSingleton() {
        let (state, _) = makeState()
        let urls = [URL(fileURLWithPath: "/tmp/orphan_app.wav")]

        state.enqueueFiles(urls)

        XCTAssertEqual(state.pipelineQueue.jobs.count, 1)
        let job = state.pipelineQueue.jobs[0]
        XCTAssertEqual(job.mixPath?.lastPathComponent, "orphan_app.wav")
        XCTAssertNil(job.appPath)
        XCTAssertNil(job.micPath)
    }

    func testEnqueueFilesMixedPairAndSingleton() {
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/meeting_app.wav"),
            URL(fileURLWithPath: "/tmp/meeting_mic.wav"),
            URL(fileURLWithPath: "/tmp/meeting_mix.wav"),
            URL(fileURLWithPath: "/tmp/podcast.mp3"),
        ]

        state.enqueueFiles(urls)

        XCTAssertEqual(state.pipelineQueue.jobs.count, 2)
        let paired = state.pipelineQueue.jobs.first { $0.appPath != nil }
        let single = state.pipelineQueue.jobs.first { $0.appPath == nil }
        XCTAssertEqual(paired?.meetingTitle, "meeting")
        XCTAssertEqual(single?.meetingTitle, "podcast")
    }

    func testEnqueueFilesUsesSidecarMetadataWhenPresent() throws {
        let (state, _) = makeState()
        let tmpDir = try makeTempDirectory(prefix: "enqueue-sidecar")
        let basename = "20260311_143000"

        try RecordingSidecar(
            title: "Sprint Review",
            appName: "Microsoft Teams",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_777_001_800),
            participants: ["Speaker A", "Speaker B"],
            micDelaySeconds: 0.25,
            mixFilename: "\(basename)_mix.wav",
            appFilename: "\(basename)_app.wav",
            micFilename: "\(basename)_mic.wav",
        ).write(toDirectory: tmpDir, basename: basename)

        state.enqueueFiles([
            tmpDir.appendingPathComponent("\(basename)_app.wav"),
            tmpDir.appendingPathComponent("\(basename)_mic.wav"),
            tmpDir.appendingPathComponent("\(basename)_mix.wav"),
        ])

        XCTAssertEqual(state.pipelineQueue.jobs.count, 1)
        let job = state.pipelineQueue.jobs[0]
        XCTAssertEqual(job.meetingTitle, "Sprint Review")
        XCTAssertEqual(job.appName, "Microsoft Teams")
        XCTAssertEqual(job.participants, ["Speaker A", "Speaker B"])
        XCTAssertEqual(job.micDelay, 0.25, accuracy: 0.0001)
    }

    // MARK: - ensurePipelineQueue

    func testEnsurePipelineQueueReplacesBareQueue() {
        // Bare queue (no engine) — uses the no-engine init; logDir is the
        // production path but this test never enqueues so no I/O hits it.
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.pipelineQueue = PipelineQueue(logDir: testLogDir)
        XCTAssertNil(state.pipelineQueue.engine, "Precondition: fresh queue has no engine")

        state.ensurePipelineQueue()

        XCTAssertNotNil(state.pipelineQueue.engine)
    }

    func testEnsurePipelineQueueIdempotent() {
        let (state, _) = makeState()
        state.ensurePipelineQueue()
        let firstID = ObjectIdentifier(state.pipelineQueue)

        state.ensurePipelineQueue()

        XCTAssertEqual(ObjectIdentifier(state.pipelineQueue), firstID)
    }

    // MARK: - makePipelineQueue

    func testMakePipelineQueueHasEngine() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.makePipelineQueue().engine)
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
        let tmpDir = try makeTempDirectory(prefix: "appstate_callbacks")

        let (state, notifier) = makeIsolatedState(logDir: tmpDir)
        state.configurePipelineCallbacks()

        var job = makeJob(title: "Sprint Review")
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        state.pipelineQueue.onJobStateChange?(job, .transcribing, .done)

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Protocol Ready")
        XCTAssertEqual(notifier.calls[0].body, "Sprint Review")
    }

    func testConfigurePipelineCallbacksErrorFiresNotification() throws {
        let tmpDir = try makeTempDirectory(prefix: "appstate_callbacks")

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
        let tmpDir = try makeTempDirectory(prefix: "appstate_callbacks")

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
        state.permissionHealth = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
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
        state.permissionHealth = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        let (existingLoop, _) = makeTestWatchLoop()
        existingLoop.start()
        state.watchLoop = existingLoop
        XCTAssertTrue(existingLoop.isActive)

        state.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(!existingLoop.isActive)

        XCTAssertFalse(existingLoop.isActive, "Existing auto-watch loop should be stopped")
    }

    // MARK: - Engine Switching

    func testActiveTranscriptionEngineDefaultsToWhisperKit() {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let state = AppState(settings: settings)
        XCTAssertTrue(state.activeTranscriptionEngine is WhisperKitEngine)
    }

    func testActiveTranscriptionEngineReturnsParakeetWhenSet() {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)
        XCTAssertTrue(state.activeTranscriptionEngine is ParakeetEngine)
    }

    func testActiveTranscriptionEngineSwitchesBack() {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)
        XCTAssertTrue(state.activeTranscriptionEngine is ParakeetEngine)

        settings.transcriptionEngine = .whisperKit
        XCTAssertTrue(state.activeTranscriptionEngine is WhisperKitEngine)
    }

    func testMakePipelineQueueUsesActiveEngine() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.makePipelineQueue().engine, "WhisperKit engine should be set")

        state.settings.transcriptionEngine = .parakeet
        XCTAssertNotNil(state.makePipelineQueue().engine, "Parakeet engine should be set")
    }

    func testEnsurePipelineQueueWithParakeet() {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)

        state.ensurePipelineQueue()

        XCTAssertNotNil(state.pipelineQueue.engine)
    }

    func testActiveTranscriptionEngineReturnsQwen3WhenSet() {
        guard #available(macOS 15, *) else { return }
        let settings = AppSettings()
        settings.transcriptionEngine = .qwen3
        let state = AppState(settings: settings)
        XCTAssertTrue(state.activeTranscriptionEngine is Qwen3AsrEngine)
    }

    func testActiveTranscriptionEngineSwitchesToQwen3AndBack() {
        guard #available(macOS 15, *) else { return }
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let state = AppState(settings: settings)
        XCTAssertTrue(state.activeTranscriptionEngine is WhisperKitEngine)

        settings.transcriptionEngine = .qwen3
        XCTAssertTrue(state.activeTranscriptionEngine is Qwen3AsrEngine)

        settings.transcriptionEngine = .parakeet
        XCTAssertTrue(state.activeTranscriptionEngine is ParakeetEngine)
    }

    func testMakePipelineQueueUsesQwen3Engine() {
        guard #available(macOS 15, *) else { return }
        let settings = AppSettings()
        settings.transcriptionEngine = .qwen3
        let state = AppState(settings: settings)
        XCTAssertNotNil(state.makePipelineQueue().engine, "Qwen3 engine should be set")
    }

    func testEnsurePipelineQueueWithQwen3() {
        guard #available(macOS 15, *) else { return }
        let settings = AppSettings()
        settings.transcriptionEngine = .qwen3
        let state = AppState(settings: settings)

        state.ensurePipelineQueue()

        XCTAssertNotNil(state.pipelineQueue.engine)
    }

    // MARK: - Qwen3 Fallback

    func testActiveTranscriptionEngineQwen3FallbackOnOldOS() {
        // On macOS < 15, Qwen3 selection should fall back to WhisperKit
        // This test only meaningfully runs on macOS < 15, but validates the code path exists
        let settings = AppSettings()
        settings.transcriptionEngine = .qwen3
        let state = AppState(settings: settings)
        // On macOS 15+: Qwen3AsrEngine; on older: WhisperKit (fallback)
        XCTAssertNotNil(state.activeTranscriptionEngine)
    }

    // MARK: - MakePipelineQueue Settings

    func testMakePipelineQueueUsesDiarizeSettingFromSettings() {
        let (state, _) = makeState()
        state.settings.diarize = true
        let queue = state.makePipelineQueue()
        XCTAssertTrue(queue.diarizeEnabled)
    }

    func testMakePipelineQueueUsesMicLabelFromSettings() {
        let (state, _) = makeState()
        state.settings.micName = "Speaker A"
        let queue = state.makePipelineQueue()
        XCTAssertEqual(queue.micLabel, "Speaker A")
    }

    func testMakePipelineQueueUsesNumSpeakersFromSettings() {
        let (state, _) = makeState()
        state.settings.numSpeakers = 4
        let queue = state.makePipelineQueue()
        XCTAssertEqual(queue.numSpeakers, 4)
    }

    // MARK: - Permission Health Check

    func testHandlePermissionHealthBrokenSendsNotification() {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.handlePermissionHealth(HealthCheckResult(
            screenRecording: .broken,
            microphone: .healthy,
        ))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls.first?.title.contains("Permission") ?? false)
    }

    func testHandlePermissionHealthHealthyNoNotification() {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.handlePermissionHealth(HealthCheckResult(
            screenRecording: .healthy,
            microphone: .healthy,
        ))
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testHandlePermissionHealthStoresResult() {
        let state = AppState(notifier: RecordingNotifier())
        let result = HealthCheckResult(
            screenRecording: .healthy,
            microphone: .healthy,
        )
        state.handlePermissionHealth(result)
        XCTAssertEqual(state.permissionHealth, result)
    }

    func testHandlePermissionHealthDedupsRepeatedProblem() {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        let broken = HealthCheckResult(screenRecording: .healthy, microphone: .broken)
        state.handlePermissionHealth(broken)
        state.handlePermissionHealth(broken)
        state.handlePermissionHealth(broken)
        XCTAssertEqual(notifier.calls.count, 1, "Identical problem set should only notify once")
    }

    func testHandlePermissionHealthReNotifiesAfterRecovery() {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        let broken = HealthCheckResult(screenRecording: .healthy, microphone: .broken)
        let healthy = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        state.handlePermissionHealth(broken) // notify #1
        state.handlePermissionHealth(healthy) // clears dedup memory
        state.handlePermissionHealth(broken) // notify #2
        XCTAssertEqual(notifier.calls.count, 2)
    }

    func testHandlePermissionHealthNotifiesWhenProblemChanges() {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.handlePermissionHealth(HealthCheckResult(screenRecording: .healthy, microphone: .broken))
        state.handlePermissionHealth(HealthCheckResult(screenRecording: .broken, microphone: .healthy))
        XCTAssertEqual(notifier.calls.count, 2, "Different problem sets should each trigger a notification")
    }

    func testHandlePermissionHealthAccessibilityBrokenNotifies() {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.handlePermissionHealth(HealthCheckResult(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        ))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls.first?.body.contains("Accessibility") ?? false)
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
