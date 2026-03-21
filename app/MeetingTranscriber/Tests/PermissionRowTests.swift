@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class PermissionRowTests: XCTestCase {
    // MARK: - Icon Tests

    func testGrantedShowsCheckmarkIcon() throws {
        let sut = PermissionRow(label: "Mic", detail: "Granted", granted: true)
        let body = try sut.inspect()
        let images = try body.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { try? $0.actualImage().name() }
        XCTAssertTrue(systemNames.contains("checkmark.circle.fill"), "Expected checkmark.circle.fill, got: \(systemNames)")
    }

    func testDeniedShowsXmarkIcon() throws {
        let sut = PermissionRow(label: "Mic", detail: "Denied", granted: false)
        let body = try sut.inspect()
        let images = try body.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { try? $0.actualImage().name() }
        XCTAssertTrue(systemNames.contains("xmark.circle.fill"), "Expected xmark.circle.fill, got: \(systemNames)")
    }

    func testWarningShowsTriangleIcon() throws {
        let sut = PermissionRow(label: "Mic", detail: "Warning", granted: false, warning: true)
        let body = try sut.inspect()
        let images = try body.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { try? $0.actualImage().name() }
        XCTAssertTrue(
            systemNames.contains("exclamationmark.triangle.fill"),
            "Expected exclamationmark.triangle.fill, got: \(systemNames)",
        )
    }

    func testOptionalShowsTriangleIcon() throws {
        let sut = PermissionRow(label: "Mic", detail: "Optional", granted: false, optional: true)
        let body = try sut.inspect()
        let images = try body.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { try? $0.actualImage().name() }
        XCTAssertTrue(
            systemNames.contains("exclamationmark.triangle.fill"),
            "Expected exclamationmark.triangle.fill, got: \(systemNames)",
        )
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
        let sut = PermissionRow(label: "Mic", detail: "Detail", granted: true, help: "some text")
        let body = try sut.inspect()
        let images = try body.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { try? $0.actualImage().name() }
        XCTAssertTrue(systemNames.contains("questionmark.circle"), "Expected questionmark.circle when help is non-empty")
    }

    func testHelpButtonHiddenWhenHelpEmpty() throws {
        let sut = PermissionRow(label: "Mic", detail: "Detail", granted: true, help: "")
        let body = try sut.inspect()
        let images = try body.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { try? $0.actualImage().name() }
        XCTAssertFalse(systemNames.contains("questionmark.circle"), "Expected no questionmark.circle when help is empty")
    }
}
