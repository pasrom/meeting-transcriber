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
        XCTAssertTrue(dir.path.contains("Library/Application Support/MeetingTranscriber/protocols"))
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
}
