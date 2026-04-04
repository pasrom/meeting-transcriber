@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class PermissionRowTests: XCTestCase {
    // MARK: - Helpers

    private func iconNames(for row: PermissionRow) throws -> [String] {
        let images = try row.inspect().findAll(ViewType.Image.self)
        return images.compactMap { try? $0.actualImage().name() }
    }

    // MARK: - Icon Tests

    func testGrantedShowsCheckmarkIcon() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Granted", granted: true))
        XCTAssertTrue(names.contains("checkmark.circle.fill"))
    }

    func testDeniedShowsXmarkIcon() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Denied", granted: false))
        XCTAssertTrue(names.contains("xmark.circle.fill"))
    }

    func testWarningShowsTriangleIcon() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Warning", granted: false, warning: true))
        XCTAssertTrue(names.contains("exclamationmark.triangle.fill"))
    }

    func testOptionalShowsTriangleIcon() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Optional", granted: false, optional: true))
        XCTAssertTrue(names.contains("exclamationmark.triangle.fill"))
    }

    // MARK: - Label & Detail

    func testLabelAndDetailRendered() throws {
        let sut = PermissionRow(label: "Microphone", detail: "Access granted", granted: true)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Microphone"))
        XCTAssertNoThrow(try body.find(text: "Access granted"))
    }

    // MARK: - Help Button

    func testHelpButtonShownWhenHelpNonEmpty() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Detail", granted: true, help: "some text"))
        XCTAssertTrue(names.contains("questionmark.circle"))
    }

    func testHelpButtonHiddenWhenHelpEmpty() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Detail", granted: true, help: ""))
        XCTAssertFalse(names.contains("questionmark.circle"))
    }

    // MARK: - Icon Priority

    func testGrantedTakesPriorityOverWarning() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Detail", granted: true, warning: true))
        XCTAssertTrue(names.contains("checkmark.circle.fill"))
        XCTAssertFalse(names.contains("exclamationmark.triangle.fill"))
    }

    func testGrantedTakesPriorityOverOptional() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Detail", granted: true, optional: true))
        XCTAssertTrue(names.contains("checkmark.circle.fill"))
    }

    func testWarningTakesPriorityOverDenied() throws {
        let names = try iconNames(for: PermissionRow(label: "Mic", detail: "Detail", granted: false, warning: true))
        XCTAssertTrue(names.contains("exclamationmark.triangle.fill"))
        XCTAssertFalse(names.contains("xmark.circle.fill"))
    }
}
