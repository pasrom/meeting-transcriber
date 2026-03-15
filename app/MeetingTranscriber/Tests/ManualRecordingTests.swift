@testable import MeetingTranscriber
import XCTest

@MainActor
final class ManualRecordingTests: XCTestCase {
    private func makeLoop(
        recorder: MockRecorder? = nil,
        pipelineQueue: PipelineQueue? = nil,
    ) -> (WatchLoop, MockRecorder) {
        let mock = recorder ?? MockRecorder()
        mock.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
        let loop = WatchLoop(
            detector: MeetingDetector(patterns: AppMeetingPattern.all),
            recorderFactory: { mock },
            pipelineQueue: pipelineQueue,
            pollInterval: 0.05,
            maxDuration: 10,
        )
        return (loop, mock)
    }

    // MARK: - Start

    func testStartManualRecordingTransitionsToRecording() throws {
        let (loop, _) = makeLoop()
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertEqual(loop.state, .recording)
        XCTAssertTrue(loop.isActive)
        loop.stop()
    }

    func testManualRecordingInfoIsSet() throws {
        let (loop, _) = makeLoop()
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        XCTAssertTrue(loop.isManualRecording)
        XCTAssertEqual(loop.manualRecordingInfo?.pid, 1234)
        XCTAssertEqual(loop.manualRecordingInfo?.appName, "Chrome")
        XCTAssertEqual(loop.manualRecordingInfo?.title, "Standup")
        loop.stop()
    }

    func testStartManualRecordingCallsRecorderStart() throws {
        let (loop, mock) = makeLoop()
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertTrue(mock.startCalled)
        loop.stop()
    }

    func testStartManualRecordingWhileAlreadyRecordingIsNoOp() throws {
        let (loop, _) = makeLoop()
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting 1")
        XCTAssertEqual(loop.state, .recording)

        // Trying to start again on the same loop should be a no-op
        try loop.startManualRecording(pid: 5678, appName: "Firefox", title: "Meeting 2")
        XCTAssertEqual(loop.manualRecordingInfo?.pid, 1234)
        loop.stop()
    }

    // MARK: - Stop

    func testStopManualRecordingEnqueuesJob() throws {
        let queue = PipelineQueue()
        let (loop, _) = makeLoop(pipelineQueue: queue)
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")

        loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Standup")
        XCTAssertEqual(queue.jobs.first?.appName, "Chrome")
    }

    func testStopManualRecordingTransitionsToIdle() throws {
        let (loop, _) = makeLoop()
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")

        loop.stopManualRecording()

        XCTAssertEqual(loop.state, .idle)
        XCTAssertFalse(loop.isManualRecording)
        XCTAssertNil(loop.manualRecordingInfo)
    }

    func testStopManualRecordingCallsRecorderStop() throws {
        let (loop, mock) = makeLoop()
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")

        loop.stopManualRecording()

        XCTAssertTrue(mock.stopCalled)
    }

    // MARK: - Stop cleanup

    func testStopCleansUpManualRecording() throws {
        let (loop, _) = makeLoop()
        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertTrue(loop.isManualRecording)

        loop.stop()

        XCTAssertFalse(loop.isManualRecording)
        XCTAssertNil(loop.manualRecordingInfo)
        XCTAssertEqual(loop.state, .idle)
    }

    // MARK: - State change callback

    func testManualRecordingTriggersStateChangeCallback() throws {
        let (loop, _) = makeLoop()
        var transitions: [(WatchLoop.State, WatchLoop.State)] = []
        loop.onStateChange = { old, new in
            transitions.append((old, new))
        }

        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions[0].0, .idle)
        XCTAssertEqual(transitions[0].1, .recording)

        loop.stopManualRecording()
        XCTAssertEqual(transitions.count, 2)
        XCTAssertEqual(transitions[1].0, .recording)
        XCTAssertEqual(transitions[1].1, .idle)
    }

    // MARK: - Auto-watch interaction

    func testStartManualRecordingStopsAutoWatch() throws {
        let (loop, _) = makeLoop()
        loop.start()
        XCTAssertEqual(loop.state, .watching)

        try loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertEqual(loop.state, .recording)
        XCTAssertTrue(loop.isManualRecording)
        loop.stop()
    }
}
