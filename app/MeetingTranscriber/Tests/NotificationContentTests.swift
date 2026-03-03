import Foundation
import XCTest

@testable import MeetingTranscriber

final class NotificationContentTests: XCTestCase {

    private func makeStatus(
        state: TranscriberState,
        meeting: MeetingInfo? = nil,
        protocolPath: String? = nil,
        error: String? = nil
    ) -> TranscriberStatus {
        TranscriberStatus(
            version: 1, timestamp: "2026-03-03T10:00:00",
            state: state, detail: "", meeting: meeting,
            protocolPath: protocolPath, error: error, pid: nil
        )
    }

    // MARK: - Recording

    func testRecordingNotification() {
        let meeting = MeetingInfo(app: "Microsoft Teams", title: "Sprint Planning", pid: 42)
        let status = makeStatus(state: .recording, meeting: meeting)

        let content = NotificationManager.notificationContent(for: .recording, status: status)

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Meeting Detected")
        XCTAssertEqual(content?.body, "Recording: Sprint Planning (Microsoft Teams)")
    }

    func testRecordingNoMeeting() {
        let status = makeStatus(state: .recording)

        let content = NotificationManager.notificationContent(for: .recording, status: status)

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.body, "Recording: Unknown ()")
    }

    // MARK: - Protocol Ready

    func testProtocolReadyNotification() {
        let meeting = MeetingInfo(app: "Zoom", title: "Design Review", pid: 99)
        let status = makeStatus(state: .protocolReady, meeting: meeting, protocolPath: "/tmp/protocol.md")

        let content = NotificationManager.notificationContent(for: .protocolReady, status: status)

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Protocol Ready")
        XCTAssertEqual(content?.body, "Protocol for \"Design Review\" is ready.")
    }

    func testProtocolReadyNoMeeting() {
        let status = makeStatus(state: .protocolReady)

        let content = NotificationManager.notificationContent(for: .protocolReady, status: status)

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.body, "Protocol for \"Meeting\" is ready.")
    }

    // MARK: - Speaker Names

    func testSpeakerNamesNotification() {
        let status = makeStatus(state: .waitingForSpeakerNames)

        let content = NotificationManager.notificationContent(for: .waitingForSpeakerNames, status: status)

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Name Speakers")
        XCTAssertEqual(content?.body, "Speakers detected — open the app to assign names")
    }

    // MARK: - Error

    func testErrorNotification() {
        let status = makeStatus(state: .error, error: "Whisper crashed")

        let content = NotificationManager.notificationContent(for: .error, status: status)

        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Transcriber Error")
        XCTAssertEqual(content?.body, "Whisper crashed")
    }

    func testErrorNoMessage() {
        let status = makeStatus(state: .error)

        let content = NotificationManager.notificationContent(for: .error, status: status)

        XCTAssertNil(content)
    }

    // MARK: - No Notification

    func testIdleNoNotification() {
        let status = makeStatus(state: .idle)

        let content = NotificationManager.notificationContent(for: .idle, status: status)

        XCTAssertNil(content)
    }
}
