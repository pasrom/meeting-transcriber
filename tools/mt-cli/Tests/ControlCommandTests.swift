@testable import mt_cli
import XCTest

/// The two `/v1` lifecycle subcommands. They share `runControl`, so the thing
/// worth pinning is which resource each one names: the copy-paste that sends
/// `mt-cli record` at `/v1/watch` compiles, runs, and starts the wrong thing.
final class ControlCommandTests: XCTestCase {
    func testEachCommandNamesItsOwnResource() {
        XCTAssertEqual(Record.resource, "/v1/record")
        XCTAssertEqual(Watch.resource, "/v1/watch")
    }

    func testBothDefaultToReadingRatherThanChanging() throws {
        XCTAssertEqual(try Record.parse([]).action, .status)
        XCTAssertEqual(try Watch.parse([]).action, .status)
    }

    func testEveryVerbParses() throws {
        for verb in ControlAction.allCases {
            XCTAssertEqual(try Record.parse([verb.rawValue]).action, verb)
        }
    }

    func testAnUnknownVerbIsRejectedRatherThanTreatedAsAToggle() {
        XCTAssertThrowsError(try Record.parse(["pause"]))
    }

    /// The control routes block until the start settles, so this bound has to
    /// sit ABOVE the server's own 20 s join. Below it the client gives up first
    /// and reports a failure for a start that then succeeds — the exact thing
    /// the constant exists to prevent, and a one-character edit away.
    func testControlTimeoutOutlivesTheServersJoinBound() {
        XCTAssertGreaterThan(RPCClient.controlTimeoutSeconds, 20)
        XCTAssertGreaterThan(RPCClient.controlTimeoutSeconds, RPCClient.requestTimeoutSeconds)
    }
}
