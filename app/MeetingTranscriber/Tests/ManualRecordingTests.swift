@testable import MeetingTranscriber
import XCTest

@MainActor
final class ManualRecordingTests: XCTestCase {
    private func makeLoop(
        recorder: MockRecorder? = nil,
        pipelineQueue: PipelineQueue? = nil,
        noMic: Bool = false,
    ) -> (WatchLoop, MockRecorder) {
        let mock = recorder ?? MockRecorder()
        mock.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
        let loop = WatchLoop(
            detector: MeetingDetector(patterns: AppMeetingPattern.all),
            recorderFactory: { mock },
            pipelineQueue: pipelineQueue,
            pollInterval: 0.05,
            maxDuration: 10,
            noMic: noMic,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, mock)
    }

    // MARK: - Start

    func testStartManualRecordingTransitionsToRecording() async throws {
        let (loop, _) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertEqual(loop.state, .recording)
        XCTAssertTrue(loop.isActive)
        loop.stop()
    }

    func testManualRecordingInfoIsSet() async throws {
        let (loop, _) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        XCTAssertTrue(loop.isManualRecording)
        XCTAssertEqual(loop.manualRecordingInfo?.pid, 1234)
        XCTAssertEqual(loop.manualRecordingInfo?.appName, "Chrome")
        XCTAssertEqual(loop.manualRecordingInfo?.title, "Standup")
        loop.stop()
    }

    func testStartManualRecordingCallsRecorderStart() async throws {
        let (loop, mock) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertTrue(mock.startCalled)
        // Not just "was start called": the manual-start pid must actually reach
        // the recorder (mock default is nil, so a dropped/wrong pid fails here).
        // Full source/micDeviceUID threading is pinned by
        // WatchLoopTests.testStartManualRecordingThreadsRecorderParams.
        XCTAssertEqual(mock.capturedSource?.appPID, 1234)
        loop.stop()
    }

    func testStartManualRecordingWhileAlreadyRecordingIsNoOp() async throws {
        let (loop, _) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting 1")
        XCTAssertEqual(loop.state, .recording)

        // Trying to start again on the same loop should be a no-op
        try await loop.startManualRecording(pid: 5678, appName: "Firefox", title: "Meeting 2")
        XCTAssertEqual(loop.manualRecordingInfo?.pid, 1234)
        loop.stop()
    }

    // MARK: - Stop

    func testStopManualRecordingEnqueuesJob() async throws {
        let queue = PipelineQueue()
        let (loop, _) = makeLoop(pipelineQueue: queue)
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")

        loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Standup")
        XCTAssertEqual(queue.jobs.first?.appName, "Chrome")
    }

    func testStopManualRecordingTransitionsToIdle() async throws {
        let (loop, _) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")

        loop.stopManualRecording()

        XCTAssertEqual(loop.state, .idle)
        XCTAssertFalse(loop.isManualRecording)
        XCTAssertNil(loop.manualRecordingInfo)
    }

    func testStopManualRecordingCallsRecorderStop() async throws {
        let (loop, mock) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")

        loop.stopManualRecording()

        XCTAssertTrue(mock.stopCalled)
    }

    // MARK: - Stop cleanup

    func testStopCleansUpManualRecording() async throws {
        let (loop, _) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertTrue(loop.isManualRecording)

        loop.stop()

        XCTAssertFalse(loop.isManualRecording)
        XCTAssertNil(loop.manualRecordingInfo)
        XCTAssertEqual(loop.state, .idle)
    }

    // MARK: - State change callback

    func testManualRecordingTriggersStateChangeCallback() async throws {
        let (loop, _) = makeLoop()
        var transitions: [(WatchLoop.State, WatchLoop.State)] = []
        loop.onStateChange = { old, new in
            transitions.append((old, new))
        }

        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions[0].0, .idle)
        XCTAssertEqual(transitions[0].1, .recording)

        loop.stopManualRecording()
        XCTAssertEqual(transitions.count, 2)
        XCTAssertEqual(transitions[1].0, .recording)
        XCTAssertEqual(transitions[1].1, .idle)
    }

    // MARK: - Microphone-only recording (issue #633)

    func testStartMicrophoneRecordingOpensNoTap() async throws {
        let (loop, mock) = makeLoop()
        try await loop.startMicrophoneRecording()
        defer { loop.stop() }

        XCTAssertEqual(
            mock.capturedSource, .micOnly,
            "a microphone recording must not tap any process; a source carrying a PID here would record whatever app happened to be at it",
        )
    }

    func testStartMicrophoneRecordingIgnoresTheNoMicSetting() async throws {
        // `noMic` governs whether an *app* recording also takes the mic. It must
        // not be able to turn the microphone entry point into a recording of
        // nothing. Refusing the request belongs to `WatchingController`, which
        // can say so; by the time the loop is asked, the answer is the mic.
        let (loop, mock) = makeLoop(noMic: true)

        try await loop.startMicrophoneRecording()
        defer { loop.stop() }

        XCTAssertEqual(mock.capturedSource, .micOnly)
    }

    func testMicrophoneRecordingHasNoTargetPID() async throws {
        let (loop, _) = makeLoop()
        try await loop.startMicrophoneRecording()
        defer { loop.stop() }

        XCTAssertTrue(loop.isManualRecording)
        XCTAssertNil(loop.manualRecordingInfo?.pid, "there is no process behind a microphone recording")
        XCTAssertEqual(loop.manualRecordingInfo?.appName, ManualRecordingInfo.microphoneAppName)
        XCTAssertEqual(loop.manualRecordingInfo?.title, ManualRecordingInfo.microphoneTitle)
    }

    func testTheLiveSourceOfAMicrophoneRecordingHasNoAppChannel() async throws {
        // What the channel-health wiring reads to decide which channels exist.
        // Getting this wrong on the manual path is what makes the indicator
        // report the absent app channel as a dead one.
        let (loop, _) = makeLoop()
        try await loop.startMicrophoneRecording()
        defer { loop.stop() }

        XCTAssertEqual(loop.activeRecordingSource, .micOnly)
    }

    func testTheLiveSourceOfAnAppRecordingCarriesItsPIDAndTheMicSetting() async throws {
        let (loop, _) = makeLoop(noMic: true)
        try await loop.startManualRecording(pid: 77, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        XCTAssertEqual(loop.activeRecordingSource, .appOnly(pid: 77))
    }

    func testThereIsNoLiveSourceWhileNothingRecords() async throws {
        let (loop, _) = makeLoop()

        XCTAssertNil(loop.activeRecordingSource, "nothing is recording, so there are no channels to watch")

        try await loop.startMicrophoneRecording()
        loop.stopManualRecording()

        XCTAssertNil(loop.activeRecordingSource, "and none again once it stopped")
    }

    func testStopMicrophoneRecordingEnqueuesJob() async throws {
        let queue = PipelineQueue()
        let (loop, _) = makeLoop(pipelineQueue: queue)
        try await loop.startMicrophoneRecording()

        loop.stopManualRecording()

        XCTAssertEqual(loop.state, .idle)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.meetingTitle, ManualRecordingInfo.microphoneTitle)
        XCTAssertEqual(queue.jobs.first?.appName, ManualRecordingInfo.microphoneAppName)
    }

    func testMicrophoneRecordingIsRefusedWithoutTheMicrophoneGrant() async {
        let (loop, mock) = makeLoop()
        loop.permissionChecker = { HealthCheckResult(screenRecording: .healthy, microphone: .denied) }

        do {
            try await loop.startMicrophoneRecording()
            XCTFail("a microphone recording without the microphone grant captures nothing")
        } catch {
            XCTAssertFalse(mock.startCalled)
            XCTAssertEqual(loop.state, .idle)
        }
    }

    func testMicrophoneRecordingStartsWithoutTheScreenRecordingGrant() async throws {
        // The other half of the gate change: no tap is opened, so the grant
        // that only ever stood in for the tap must not refuse this.
        let (loop, _) = makeLoop()
        loop.permissionChecker = { HealthCheckResult(screenRecording: .denied, microphone: .healthy) }

        try await loop.startMicrophoneRecording()
        defer { loop.stop() }

        XCTAssertEqual(loop.state, .recording)
    }

    func testSecondMicrophoneRecordingWhileRecordingIsNoOp() async throws {
        let (loop, _) = makeLoop()
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")

        try await loop.startMicrophoneRecording()

        XCTAssertEqual(loop.manualRecordingInfo?.pid, 1234, "the running app recording must survive")
        loop.stop()
    }

    // MARK: - Auto-watch interaction

    func testStartManualRecordingStopsAutoWatch() async throws {
        let (loop, _) = makeLoop()
        loop.start()
        XCTAssertEqual(loop.state, .watching)

        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        XCTAssertEqual(loop.state, .recording)
        XCTAssertTrue(loop.isManualRecording)
        loop.stop()
    }
}
