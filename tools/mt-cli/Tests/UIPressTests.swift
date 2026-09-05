@testable import mt_cli
import XCTest

/// `--via` gates whether `ui-press` posts a real click instead of an AX press —
/// a Settings sidebar tab row silently no-ops without it (see `PressVia`'s doc
/// comment). Pinning the parse here is cheap; the real proof that a missing
/// `--via` breaks the About tab lives in `scripts/test_rpc.sh`.
final class UIPressTests: XCTestCase {
    func testViaDefaultsToNilSoOlderCallsKeepUsingAXPress() throws {
        let command = try UIPress.parse(["someIdentifier"])
        XCTAssertNil(command.via)
    }

    func testViaClickParses() throws {
        let command = try UIPress.parse(["someIdentifier", "--via", "click"])
        XCTAssertEqual(command.via, .click)
    }

    func testViaAxParses() throws {
        let command = try UIPress.parse(["someIdentifier", "--via", "ax"])
        XCTAssertEqual(command.via, .ax)
    }

    func testUnknownViaIsRejected() {
        XCTAssertThrowsError(try UIPress.parse(["someIdentifier", "--via", "double-click"]))
    }
}
