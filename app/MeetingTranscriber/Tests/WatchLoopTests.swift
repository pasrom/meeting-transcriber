@testable import MeetingTranscriber
import XCTest

@MainActor
final class WatchLoopTests: XCTestCase {
    private func makeLoop(pipelineQueue: PipelineQueue? = nil) -> WatchLoop {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = { [:] }
        return WatchLoop(
            detector: detector,
            pipelineQueue: pipelineQueue,
        )
    }

    // MARK: - Initial State

    func testInitialState() {
        let loop = makeLoop()
        XCTAssertEqual(loop.state, .idle)
        XCTAssertFalse(loop.isActive)
        XCTAssertNil(loop.currentMeeting)
        XCTAssertNil(loop.lastError)
    }

    // MARK: - Start / Stop

    func testStartTransitionsToWatching() {
        let loop = makeLoop()
        loop.start()
        XCTAssertEqual(loop.state, .watching)
        XCTAssertTrue(loop.isActive)
        loop.stop()
    }

    func testStopTransitionsToIdle() {
        let loop = makeLoop()
        loop.start()
        loop.stop()
        XCTAssertEqual(loop.state, .idle)
        XCTAssertFalse(loop.isActive)
    }

    func testDoubleStartIsNoOp() {
        let loop = makeLoop()
        loop.start()
        loop.start() // should not crash or create second task
        XCTAssertEqual(loop.state, .watching)
        loop.stop()
    }

    func testStopWithoutStartIsNoOp() {
        let loop = makeLoop()
        loop.stop() // should not crash
        XCTAssertEqual(loop.state, .idle)
    }

    // MARK: - State Change Callback

    func testOnStateChangeCallback() {
        let loop = makeLoop()
        var transitions: [(WatchLoop.State, WatchLoop.State)] = []
        loop.onStateChange = { old, new in
            transitions.append((old, new))
        }

        loop.start()
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions[0].0, .idle)
        XCTAssertEqual(transitions[0].1, .watching)

        loop.stop()
        XCTAssertEqual(transitions.count, 2)
        XCTAssertEqual(transitions[1].0, .watching)
        XCTAssertEqual(transitions[1].1, .idle)
    }

    // MARK: - Clean Title

    func testCleanTitleTeams() {
        XCTAssertEqual(
            WatchLoop.cleanTitle("Daily Standup | Microsoft Teams"),
            "Daily Standup",
        )
    }

    func testCleanTitleZoom() {
        XCTAssertEqual(
            WatchLoop.cleanTitle("Project Review - Zoom"),
            "Project Review",
        )
    }

    func testCleanTitleWebex() {
        XCTAssertEqual(
            WatchLoop.cleanTitle("Sprint Planning - Webex"),
            "Sprint Planning",
        )
    }

    func testCleanTitleNoSuffix() {
        XCTAssertEqual(
            WatchLoop.cleanTitle("Just a Meeting"),
            "Just a Meeting",
        )
    }

    // MARK: - Transcriber State Mapping

    func testTranscriberStateMapping() {
        let loop = makeLoop()

        // idle
        XCTAssertEqual(loop.transcriberState, .idle)

        // watching
        loop.start()
        XCTAssertEqual(loop.transcriberState, .watching)
        loop.stop()
    }

    // MARK: - Default Output Dir

    func testDefaultOutputDir() {
        let dir = WatchLoop.defaultOutputDir
        XCTAssertTrue(dir.path.contains("Downloads/MeetingTranscriber"))
    }

    // MARK: - Meeting End Detection

    func testWaitForMeetingEndGracePeriod() async throws {
        let detector = PowerAssertionDetector()
        // Mock: meeting gone (no assertions)
        detector.assertionProvider = { [:] }

        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
        )

        let meeting = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 1234,
        )

        // Should return after grace period expires
        let start = Date()
        try await loop.waitForMeetingEnd(meeting)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.1, "Should wait at least the grace period")
        XCTAssertLessThan(elapsed, 1.0, "Should not wait too long")
    }

    // MARK: - NoMic Configuration

    func testNoMicDefault() {
        let loop = makeLoop()
        XCTAssertFalse(loop.noMic)
    }

    // MARK: - PipelineQueue Configuration

    func testPipelineQueueDefault() {
        let loop = makeLoop()
        XCTAssertNil(loop.pipelineQueue)
    }

    func testPipelineQueueInit() {
        let queue = PipelineQueue()
        let loop = makeLoop(pipelineQueue: queue)
        XCTAssertNotNil(loop.pipelineQueue)
    }

    // MARK: - Meeting End Detection (Max Duration)

    func testWaitForMeetingEndMaxDuration() async throws {
        let detector = PowerAssertionDetector()
        // Mock: meeting stays active forever (assertion always present)
        detector.assertionProvider = {
            [1234: [["Process Name": "MSTeams", "AssertName": "Microsoft Teams Call in progress"]]]
        }

        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            maxDuration: 0.15, // very short for testing
        )

        let meeting = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 1234,
        )

        let start = Date()
        try await loop.waitForMeetingEnd(meeting)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.15, "Should wait at least maxDuration")
        XCTAssertLessThan(elapsed, 1.0, "Should not wait too long")
    }

    // MARK: - Cancellation

    func testStopDuringWatchingCleansUp() {
        let loop = makeLoop()
        loop.start()
        XCTAssertEqual(loop.state, .watching)

        loop.stop()
        XCTAssertEqual(loop.state, .idle)
        XCTAssertFalse(loop.isActive)
    }

    // MARK: - Pipeline Queue Wiring

    func testPipelineQueuePassedToConstructor() {
        let queue = PipelineQueue()
        let loop = WatchLoop(
            detector: PowerAssertionDetector(),
            pipelineQueue: queue,
        )
        XCTAssertNotNil(loop.pipelineQueue)
    }

    // MARK: - Manual Recording

    func testStartManualRecordingChangesState() async throws {
        let (loop, recorder) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        XCTAssertTrue(loop.isManualRecording)
        XCTAssertTrue(recorder.startCalled)
    }

    func testManualRecordingHasMeetingInfo() async throws {
        let (loop, _) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 42, appName: "Safari", title: "Standup")
        defer { loop.stop() }

        XCTAssertEqual(loop.manualRecordingInfo?.appName, "Safari")
        XCTAssertEqual(loop.manualRecordingInfo?.title, "Standup")
    }

    func testStopManualRecordingClearsState() async throws {
        let (loop, _) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        loop.stop()

        XCTAssertFalse(loop.isManualRecording)
        XCTAssertEqual(loop.state, .idle)
    }

    // MARK: - Clean Title Edge Cases

    func testCleanTitleNoMatchReturnsOriginal() {
        XCTAssertEqual(
            WatchLoop.cleanTitle("Some Random Window"),
            "Some Random Window",
        )
    }

    func testCleanTitleMultiplePipes() {
        // Only the last pipe-separated suffix should be removed for Teams
        XCTAssertEqual(
            WatchLoop.cleanTitle("Channel | Meeting | Microsoft Teams"),
            "Channel | Meeting",
        )
    }

    // MARK: - Stop Manual Recording Enqueues Job

    func testStopManualRecordingEnqueuesJob() async throws {
        let queue = PipelineQueue()
        let (loop, recorder) = makeTestWatchLoop(pipelineQueue: queue)
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")

        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
        XCTAssertTrue(loop.isManualRecording)

        loop.stopManualRecording()

        XCTAssertFalse(loop.isManualRecording)
        XCTAssertEqual(loop.state, .idle)
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Standup")
        XCTAssertEqual(queue.jobs.first?.appName, "Chrome")
    }

    // MARK: - Double Start Manual Recording

    func testStartManualRecordingWhileRecordingIsNoOp() async throws {
        let (loop, recorder) = makeTestWatchLoop()

        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "First")
        defer { loop.stop() }

        XCTAssertTrue(loop.isManualRecording)
        XCTAssertEqual(loop.manualRecordingInfo?.title, "First")

        // Second start should be ignored because state is already .recording
        try await loop.startManualRecording(pid: 99, appName: "Safari", title: "Second")

        XCTAssertEqual(loop.manualRecordingInfo?.title, "First")
        XCTAssertTrue(recorder.startCalled)
    }

    // MARK: - Permission Pre-Check

    func testManualRecordingFailsWhenPermissionBroken() async {
        let (loop, _) = makeTestWatchLoop()
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .broken)
        }

        do {
            try await loop.startManualRecording(pid: 123, appName: "Test", title: "Test")
            XCTFail("Expected permissionDenied error")
        } catch let error as RecorderError {
            if case let .permissionDenied(reason) = error {
                XCTAssertTrue(reason.contains("Microphone"))
            } else {
                XCTFail("Expected permissionDenied, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - RecordOnlyDestination

    func test_production_destinationSplitsScopeAndWriteDir() {
        let parent = URL(fileURLWithPath: "/tmp/picked")
        let dest = RecordOnlyDestination.production(parent: parent)
        // Scope is the bookmark-resolved parent — start-access target.
        XCTAssertEqual(dest.scope, parent)
        // Files land in the `recordings/` subfolder of that scope.
        XCTAssertEqual(dest.writeDir.lastPathComponent, "recordings")
        XCTAssertEqual(dest.writeDir.deletingLastPathComponent().path, parent.path)
    }

    func test_unscoped_destinationCollapsesScopeAndWriteDir() {
        let url = URL(fileURLWithPath: "/tmp/local")
        let dest = RecordOnlyDestination.unscoped(url)
        // Identical so start-access on `scope` is harmless and writes hit `url`.
        XCTAssertEqual(dest.scope, url)
        XCTAssertEqual(dest.writeDir, url)
    }

    // MARK: - Record-Only Mode

    /// Drives a complete `start → stop` manual recording cycle so the test
    /// exercises the public surface (`stopManualRecording`) rather than the
    /// private `enqueueRecording` it forwards to.
    private func runManualRecordOnlyRecording(
        recorderMix: URL,
        outputDir: URL,
        queue: PipelineQueue,
        recorderApp: URL? = nil,
        recorderMic: URL? = nil,
        title: String = "Standup",
        appName: String = "Microsoft Teams",
        notifier: any AppNotifying = SilentNotifier(),
    ) async throws -> WatchLoop {
        let (loop, recorder) = makeTestWatchLoop(
            pipelineQueue: queue,
            recordOnly: { true },
            recordOnlyOutputDir: { outputDir },
            notifier: notifier,
        )
        recorder.mixPath = recorderMix
        recorder.appPath = recorderApp
        recorder.micPath = recorderMic
        try await loop.startManualRecording(pid: 42, appName: appName, title: title)
        loop.stopManualRecording()
        return loop
    }

    func test_recordOnly_writesSidecarAndDoesNotEnqueue() async throws {
        let queue = PipelineQueue()
        let tmp = try makeTempDirectory(prefix: "recordOnly")

        let mixURL = tmp.appendingPathComponent("20260503_120000_mix.wav")
        let appURL = tmp.appendingPathComponent("20260503_120000_app.wav")
        let micURL = tmp.appendingPathComponent("20260503_120000_mic.wav")
        try Data().write(to: mixURL)
        try Data().write(to: appURL)
        try Data().write(to: micURL)

        let destDir = tmp.appendingPathComponent("dest", isDirectory: true)
        _ = try await runManualRecordOnlyRecording(
            recorderMix: mixURL,
            outputDir: destDir,
            queue: queue,
            recorderApp: appURL,
            recorderMic: micURL,
        )

        XCTAssertTrue(queue.jobs.isEmpty, "record-only must not enqueue a pipeline job")

        let sidecarURL = destDir.appendingPathComponent("20260503_120000_meta.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "sidecar should be written into the record-only output directory",
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destDir.appendingPathComponent("20260503_120000_mix.wav").path,
            ),
            "mix WAV should be moved into the record-only output directory",
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mixURL.path),
            "original mix WAV should be moved (not copied) out of the recorder's transient dir",
        )

        let data = try Data(contentsOf: sidecarURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(RecordingSidecar.self, from: data)

        XCTAssertEqual(sidecar.title, "Standup")
        XCTAssertEqual(sidecar.appName, "Microsoft Teams")
        XCTAssertEqual(sidecar.files.mix, "20260503_120000_mix.wav")
        XCTAssertEqual(sidecar.files.app, "20260503_120000_app.wav")
        XCTAssertEqual(sidecar.files.mic, "20260503_120000_mic.wav")
        // startedAt must precede stoppedAt — we don't pin exact wall-clock
        // values because the manual-recording flow records its own startTime.
        XCTAssertLessThanOrEqual(sidecar.startedAt, sidecar.stoppedAt)
    }

    func test_recordOnly_sidecarWriteFailure_setsLastErrorAndNotifies() async throws {
        // `/dev/null` is not a directory — createDirectory(at:) will throw,
        // exercising the failure path.
        let unwritable = URL(fileURLWithPath: "/dev/null/cannot-write")
        let mixURL = makeTempFile(suffix: "_mix.wav")
        try Data().write(to: mixURL)
        let notifier = RecordingNotifier()

        let queue = PipelineQueue()
        let loop = try await runManualRecordOnlyRecording(
            recorderMix: mixURL,
            outputDir: unwritable,
            queue: queue,
            notifier: notifier,
        )

        XCTAssertTrue(queue.jobs.isEmpty, "record-only must not enqueue even on sidecar failure")
        XCTAssertNotNil(loop.lastError, "lastError must be set so failures are observable")
        XCTAssertEqual(notifier.calls.count, 1, "user must be notified on sidecar write failure")
        XCTAssertEqual(notifier.calls.first?.title, "Record-only output failed")
    }

    func test_normalMode_enqueuesAndWritesNoSidecar() async throws {
        let queue = PipelineQueue()
        let tmp = try makeTempDirectory(prefix: "normalMode")

        let mixURL = tmp.appendingPathComponent("20260503_120000_mix.wav")
        try Data().write(to: mixURL)

        let (loop, recorder) = makeTestWatchLoop(pipelineQueue: queue)
        recorder.mixPath = mixURL
        try await loop.startManualRecording(pid: 42, appName: "Microsoft Teams", title: "Standup")
        loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Standup")

        let sidecarURL = tmp.appendingPathComponent("20260503_120000_meta.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "sidecar must not be written in normal mode",
        )
    }

    func testManualRecordingProceedsWhenPermissionsHealthy() async throws {
        let (loop, recorder) = makeTestWatchLoop()
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")

        try await loop.startManualRecording(pid: 123, appName: "Test", title: "Test")
        XCTAssertTrue(recorder.startCalled)
    }
}
