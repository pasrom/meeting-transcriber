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
