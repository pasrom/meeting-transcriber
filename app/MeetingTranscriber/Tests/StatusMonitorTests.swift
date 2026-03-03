import Foundation
import XCTest

@testable import MeetingTranscriber

final class StatusMonitorTests: XCTestCase {

    // MARK: - processIsAlive

    func testProcessIsAliveForCurrentProcess() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(StatusMonitor.processIsAlive(Int(pid)))
    }

    func testProcessIsAliveForDeadPID() {
        XCTAssertFalse(StatusMonitor.processIsAlive(99999))
    }

    // MARK: - parseStatus

    func testParseStatusFromValidJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_status_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pid = ProcessInfo.processInfo.processIdentifier
        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "state": "recording",
            "detail": "Recording in progress",
            "meeting": null,
            "protocol_path": null,
            "error": null,
            "pid": \(pid)
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let status = StatusMonitor.parseStatus(from: tmp)

        XCTAssertNotNil(status)
        XCTAssertEqual(status?.state, .recording)
        XCTAssertEqual(status?.detail, "Recording in progress")
    }

    func testParseStatusIgnoresInvalidJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_status_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "not valid json".write(to: tmp, atomically: true, encoding: .utf8)

        let status = StatusMonitor.parseStatus(from: tmp)
        XCTAssertNil(status)
    }

    func testParseStatusIgnoresDeadPID() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_status_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "state": "recording",
            "detail": "",
            "meeting": null,
            "protocol_path": null,
            "error": null,
            "pid": 99999
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let status = StatusMonitor.parseStatus(from: tmp)
        XCTAssertNil(status)
    }
}
