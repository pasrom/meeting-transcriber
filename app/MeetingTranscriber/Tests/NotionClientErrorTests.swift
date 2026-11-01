import Foundation
@testable import MeetingTranscriber
import XCTest

/// The two texts a Notion failure produces: the message for the user and the
/// fixed cause shown in a job warning. The cause must never carry Notion's
/// response text, which can quote meeting content back.
final class NotionClientErrorTests: XCTestCase {
    func testEveryErrorHasAMessageForTheUser() {
        XCTAssertEqual(NotionClientError.invalidID("bad id").errorDescription, "bad id")
        XCTAssertEqual(NotionClientError.missingDatabaseID.errorDescription, "No Notion Database ID configured.")
        XCTAssertEqual(
            NotionClientError.missingTitleProperty.errorDescription,
            "This Notion database has no title column, so a page cannot be created in it.",
        )
        XCTAssertEqual(
            NotionClientError.databaseInTrash.errorDescription,
            "This Notion database is in the trash. Restore it in Notion or choose another database.",
        )
        XCTAssertEqual(NotionClientError.invalidResponse.errorDescription, "Invalid response received from Notion.")
        XCTAssertEqual(
            NotionClientError.httpError(statusCode: 418, message: "teapot").errorDescription,
            "Notion error (HTTP 418): teapot",
        )
    }

    func testEveryErrorHasAFixedCauseForTheJobWarning() {
        let reason = { (error: any Error) in NotionClientError.exportFailureReason(for: error) }
        XCTAssertEqual(reason(NotionClientError.invalidID("secret")), "invalid database ID")
        XCTAssertEqual(reason(NotionClientError.missingDatabaseID), "invalid database ID")
        XCTAssertEqual(reason(NotionClientError.missingTitleProperty), "database has no title column")
        XCTAssertEqual(reason(NotionClientError.databaseInTrash), "database is in the trash")
        XCTAssertEqual(reason(NotionClientError.invalidResponse), "unexpected response from Notion")
        XCTAssertEqual(reason(NotionClientError.httpError(statusCode: 403, message: "secret")), "integration lacks permission")
        XCTAssertEqual(reason(NotionClientError.httpError(statusCode: 429, message: "secret")), "rate limited by Notion")
    }

    func testCausesOutsideTheClientHaveFixedTextToo() {
        let reason = { (error: any Error) in NotionClientError.exportFailureReason(for: error) }
        XCTAssertEqual(reason(NotionBlockTooLargeError()), "a block is too large for Notion")
        XCTAssertEqual(reason(CancellationError()), "cancelled")
        XCTAssertEqual(reason(NotionExportDeadlineExceeded()), "time limit reached")
        XCTAssertEqual(reason(CocoaError(.fileReadUnknown)), "unexpected response from Notion")
    }

    func testOnlyAnHTTPErrorCarriesAStatusCode() {
        XCTAssertEqual(NotionClientError.httpError(statusCode: 502, message: "x").httpStatusCode, 502)
        XCTAssertNil(NotionClientError.invalidResponse.httpStatusCode)
    }
}
