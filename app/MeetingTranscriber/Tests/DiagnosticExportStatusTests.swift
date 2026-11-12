@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// What Settings says after Export Diagnostics. The decision is a pure value;
/// one ViewInspector test pins that the Diagnostics section renders it.
final class DiagnosticExportStatusTests: XCTestCase {
    func test_exportWithEntries_namesTheFile() {
        let status = DiagnosticExportStatus(fileName: "diag.log", outcome: .success(12))
        XCTAssertEqual(status.message, "Exported to: diag.log")
        XCTAssertEqual(status.kind, .exported)
    }

    /// A notice-only export is a success, but must not read like a full one.
    func test_exportWithoutEntries_saysTheFileHoldsNoRecentEntries() {
        let status = DiagnosticExportStatus(fileName: "diag.log", outcome: .success(0))
        XCTAssertEqual(
            status.message,
            "Exported to: diag.log. It holds no recent log entries; the file says why.",
        )
        XCTAssertEqual(status.kind, .exportedWithoutEntries)
    }

    func test_failedExport_showsTheError() {
        let error = NSError(domain: "TestDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        let status = DiagnosticExportStatus(fileName: "diag.log", outcome: .failure(error))
        XCTAssertEqual(status.message, "Export failed: disk full")
        XCTAssertEqual(status.kind, .failed)
    }

    @MainActor
    func test_statusText_rendersTheStatusMessage() throws {
        let status = DiagnosticExportStatus(fileName: "diag.log", outcome: .success(0))
        let text = try DiagnosticExportStatusText(status: status).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.diagnosticExportStatus)
            .text().string()
        XCTAssertEqual(text, "Exported to: diag.log. It holds no recent log entries; the file says why.")
    }
}
