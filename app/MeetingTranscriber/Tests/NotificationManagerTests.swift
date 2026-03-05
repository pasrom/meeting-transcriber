import Foundation
import XCTest

@testable import MeetingTranscriber

final class NotificationManagerTests: XCTestCase {

    // MARK: - isSetUp starts false

    func testIsSetUpFalseByDefault() {
        let manager = NotificationManager()
        XCTAssertFalse(manager.isSetUp)
    }

    // MARK: - notify without setUp is no-op

    func testNotifyWithoutSetUpDoesNotCrash() {
        let manager = NotificationManager()
        // isSetUp is false — notify should silently return
        manager.notify(title: "Test", body: "Should be ignored")
        XCTAssertFalse(manager.isSetUp)
    }

    // MARK: - handleTransition without setUp is no-op

    func testHandleTransitionWithoutSetUpDoesNotCrash() {
        let manager = NotificationManager()
        let status = TranscriberStatus(
            version: 1, timestamp: "2026-03-03T10:00:00",
            state: .recording, detail: "",
            meeting: MeetingInfo(app: "Teams", title: "Standup", pid: 1),
            protocolPath: nil, error: nil, audioPath: nil, pid: nil
        )
        // recording state would normally trigger a notification, but setUp was
        // never called so notify() should be a no-op
        manager.handleTransition(from: nil, to: .recording, status: status)
    }

    func testHandleTransitionNoNotificationForIdle() {
        let manager = NotificationManager()
        let status = TranscriberStatus(
            version: 1, timestamp: "2026-03-03T10:00:00",
            state: .idle, detail: "", meeting: nil,
            protocolPath: nil, error: nil, audioPath: nil, pid: nil
        )
        manager.handleTransition(from: nil, to: .idle, status: status)
    }

    func testHandleTransitionSameStateTwice() {
        let manager = NotificationManager()
        let status = TranscriberStatus(
            version: 1, timestamp: "2026-03-03T10:00:00",
            state: .recording, detail: "", meeting: nil,
            protocolPath: nil, error: nil, audioPath: nil, pid: nil
        )
        manager.handleTransition(from: nil, to: .recording, status: status)
        manager.handleTransition(from: .recording, to: .recording, status: status)
    }

    // MARK: - shared singleton

    func testSharedIsSingleton() {
        let a = NotificationManager.shared
        let b = NotificationManager.shared
        XCTAssertTrue(a === b)
    }
}
