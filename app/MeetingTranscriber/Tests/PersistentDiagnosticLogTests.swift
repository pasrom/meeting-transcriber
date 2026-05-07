@testable import MeetingTranscriber
import XCTest

final class PersistentDiagnosticLogTests: XCTestCase {
    func test_logFileName_isYYYYMMDD() {
        let date = ISO8601DateFormatter().date(from: "2026-05-04T12:00:00Z") ?? Date()
        XCTAssertEqual(
            PersistentDiagnosticLog.logFileName(for: date),
            "diagnostics-2026-05-04.log",
        )
    }

    func test_isExpired_olderThan30Days_returnsTrue() {
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        XCTAssertTrue(PersistentDiagnosticLog.isExpired(modifiedAt: cutoff, retentionDays: 30))
    }

    func test_isExpired_youngerThan30Days_returnsFalse() {
        let recent = Date().addingTimeInterval(-15 * 86400)
        XCTAssertFalse(PersistentDiagnosticLog.isExpired(modifiedAt: recent, retentionDays: 30))
    }

    func test_isExpired_atBoundary_returnsTrue() {
        let edge = Date().addingTimeInterval(-30 * 86400 - 1)
        XCTAssertTrue(PersistentDiagnosticLog.isExpired(modifiedAt: edge, retentionDays: 30))
    }

    func test_isOurLogFile_matchesExpectedPattern() {
        XCTAssertTrue(PersistentDiagnosticLog.isOurLogFile("diagnostics-2026-05-04.log"))
        XCTAssertTrue(PersistentDiagnosticLog.isOurLogFile("diagnostics-2026-12-31.log"))
    }

    func test_isOurLogFile_rejectsForeignNames() {
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("readme.md"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("diagnostics-bad.log"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("diagnostics-26-05-04.log"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("diagnostics-2026-05-04.txt"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile(""))
    }

    // MARK: - cleanup

    func test_cleanup_removesExpiredFiles_keepsRecentOnes_doesNotTouchOthers() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentDiagnosticLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expiredFile = tmp.appendingPathComponent("diagnostics-2026-04-01.log")
        let recentFile = tmp.appendingPathComponent("diagnostics-2026-05-01.log")
        let foreign = tmp.appendingPathComponent("readme.md")

        try "old".write(to: expiredFile, atomically: true, encoding: .utf8)
        try "new".write(to: recentFile, atomically: true, encoding: .utf8)
        try "huh".write(to: foreign, atomically: true, encoding: .utf8)

        let oldDate = Date().addingTimeInterval(-31 * 86400)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: expiredFile.path,
        )
        // Backdate foreign file too — cleanup must still leave it alone.
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: foreign.path,
        )

        PersistentDiagnosticLog.cleanup(in: tmp, retentionDays: 30)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreign.path),
            "Cleanup must not touch non-matching files even when expired",
        )
    }

    func test_cleanup_emptyDirectory_doesNotCrash() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentDiagnosticLogTests-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        PersistentDiagnosticLog.cleanup(in: tmp, retentionDays: 30)
    }

    func test_cleanup_missingDirectory_doesNotCrash() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentDiagnosticLogTests-missing-\(UUID().uuidString)")
        PersistentDiagnosticLog.cleanup(in: bogus, retentionDays: 30)
    }

    // MARK: - Streamer day-rotation

    #if !APPSTORE
        func test_streamer_rotatesToNewFileWhenDayChanges() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("StreamerRotation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            var clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T23:59:50Z"),
            )
            let streamer = try PersistentDiagnosticLog.Streamer(logDirectory: tmp) { clock }

            streamer.append(Data("before-midnight\n".utf8))

            clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-05T00:00:10Z"),
            )
            streamer.append(Data("after-midnight\n".utf8))

            let day1 = tmp.appendingPathComponent("diagnostics-2026-05-04.log")
            let day2 = tmp.appendingPathComponent("diagnostics-2026-05-05.log")

            XCTAssertEqual(try String(contentsOf: day1), "before-midnight\n")
            XCTAssertEqual(try String(contentsOf: day2), "after-midnight\n")
        }

        func test_streamer_keepsSameFileWhenDayUnchanged() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("StreamerRotation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            var clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T08:00:00Z"),
            )
            let streamer = try PersistentDiagnosticLog.Streamer(logDirectory: tmp) { clock }

            streamer.append(Data("a\n".utf8))
            clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T20:00:00Z"),
            )
            streamer.append(Data("b\n".utf8))

            let day1 = tmp.appendingPathComponent("diagnostics-2026-05-04.log")
            XCTAssertEqual(try String(contentsOf: day1), "a\nb\n")
            // No second file should appear.
            let entries = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            XCTAssertEqual(entries.sorted(), ["diagnostics-2026-05-04.log"])
        }

        /// Regression guard: rotation must open the new handle BEFORE closing
        /// the old one. If the old handle is closed eagerly and the new open
        /// fails, every subsequent `append` would write to a closed FD and
        /// silently drop entries.
        func test_streamer_keepsWritingToOldFileWhenRotationOpenFails() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("StreamerRotation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer {
                // Make the directory writable again so cleanup can remove it.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: tmp.path,
                )
                try? FileManager.default.removeItem(at: tmp)
            }

            var clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-04T23:59:50Z"),
            )
            let streamer = try PersistentDiagnosticLog.Streamer(logDirectory: tmp) { clock }
            streamer.append(Data("before\n".utf8))

            // Make the directory read-only so creating tomorrow's file fails.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: tmp.path,
            )

            clock = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-05-05T00:00:10Z"),
            )
            streamer.append(Data("after\n".utf8))

            // Old file kept being writable — entry landed there, not dropped.
            let day1 = tmp.appendingPathComponent("diagnostics-2026-05-04.log")
            XCTAssertEqual(try String(contentsOf: day1), "before\nafter\n")
        }
    #endif
}
