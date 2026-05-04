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
}
