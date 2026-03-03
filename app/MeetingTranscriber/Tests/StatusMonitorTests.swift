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

    // MARK: - parseStatus with nil PID (no process check)

    func testParseStatusNilPIDReturnsStatus() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_status_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "state": "watching",
            "detail": "Watching for meetings",
            "meeting": null,
            "protocol_path": null,
            "error": null,
            "pid": null
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let status = StatusMonitor.parseStatus(from: tmp)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.state, .watching)
    }

    // MARK: - parseStatus missing file

    func testParseStatusMissingFileReturnsNil() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")
        XCTAssertNil(StatusMonitor.parseStatus(from: nonexistent))
    }

    // MARK: - parseStatus with meeting info

    func testParseStatusWithMeeting() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_status_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pid = ProcessInfo.processInfo.processIdentifier
        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "state": "recording",
            "detail": "Recording Teams",
            "meeting": {"app": "Microsoft Teams", "title": "Standup", "pid": 1234},
            "protocol_path": null,
            "error": null,
            "pid": \(pid)
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let status = StatusMonitor.parseStatus(from: tmp)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.meeting?.app, "Microsoft Teams")
        XCTAssertEqual(status?.meeting?.title, "Standup")
    }

    // MARK: - parseStatus with error state

    func testParseStatusErrorState() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_status_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pid = ProcessInfo.processInfo.processIdentifier
        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "state": "error",
            "detail": "Fatal error",
            "meeting": null,
            "protocol_path": null,
            "error": "Whisper model not found",
            "pid": \(pid)
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let status = StatusMonitor.parseStatus(from: tmp)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.state, .error)
        XCTAssertEqual(status?.error, "Whisper model not found")
    }

    // MARK: - parseStatus with protocol_path

    func testParseStatusProtocolPath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_status_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pid = ProcessInfo.processInfo.processIdentifier
        let json = """
        {
            "version": 1,
            "timestamp": "2026-03-03T10:00:00",
            "state": "protocol_ready",
            "detail": "Done",
            "meeting": null,
            "protocol_path": "/tmp/protocols/meeting.md",
            "error": null,
            "pid": \(pid)
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let status = StatusMonitor.parseStatus(from: tmp)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.protocolPath, "/tmp/protocols/meeting.md")
    }

    // MARK: - stop() is idempotent

    func testStopIdempotent() {
        let monitor = StatusMonitor()
        // stop() without start() should not crash
        monitor.stop()
        monitor.stop()
    }
}
