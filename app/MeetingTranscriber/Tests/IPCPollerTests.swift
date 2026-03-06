import XCTest
@testable import MeetingTranscriber

final class IPCPollerTests: XCTestCase {
    private var tmpDir: URL!
    private var poller: IPCPoller!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipc_poller_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        poller = IPCPoller(ipcDir: tmpDir, pollInterval: 0.1)
    }

    override func tearDown() async throws {
        poller.stop()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testDetectsSpeakerCountRequest() async throws {
        let expectation = XCTestExpectation(description: "speaker count request detected")
        var receivedRequest: SpeakerCountRequest?

        poller.onSpeakerCountRequest = { request in
            receivedRequest = request
            expectation.fulfill()
        }
        poller.start()

        let request = SpeakerCountRequest(version: 1, timestamp: "2026-03-06T12:00:00", meetingTitle: "Test")
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedRequest?.meetingTitle, "Test")
    }

    func testDetectsSpeakerRequest() async throws {
        let expectation = XCTestExpectation(description: "speaker request detected")
        var receivedRequest: SpeakerRequest?

        poller.onSpeakerRequest = { request in
            receivedRequest = request
            expectation.fulfill()
        }
        poller.start()

        let request = SpeakerRequest(
            version: 1, timestamp: "2026-03-06T12:00:00",
            meetingTitle: "Test", audioSamplesDir: "/tmp",
            speakers: [SpeakerInfo(label: "SPEAKER_00", autoName: "Alice",
                                   confidence: 0.9, speakingTimeSeconds: 30, sampleFile: "s0.wav")]
        )
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_request.json"))

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedRequest?.speakers.count, 1)
    }

    func testDoesNotFireWhenStopped() async throws {
        var called = false
        poller.onSpeakerCountRequest = { _ in called = true }
        // Don't start the poller

        let request = SpeakerCountRequest(version: 1, timestamp: "2026-03-06T12:00:00", meetingTitle: "Test")
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(called)
    }

    func testDoesNotFireTwiceForSameFile() async throws {
        var callCount = 0
        let expectation = XCTestExpectation(description: "called once")

        poller.onSpeakerCountRequest = { _ in
            callCount += 1
            expectation.fulfill()
        }
        poller.start()

        let request = SpeakerCountRequest(version: 1, timestamp: "2026-03-06T12:00:00", meetingTitle: "Test")
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        await fulfillment(of: [expectation], timeout: 2.0)
        // Wait a bit more to ensure no duplicate
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(callCount, 1)
    }
}
