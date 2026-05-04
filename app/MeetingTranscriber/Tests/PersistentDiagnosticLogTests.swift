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
}
