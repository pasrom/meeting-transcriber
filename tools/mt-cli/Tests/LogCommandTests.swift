@testable import mt_cli
import XCTest

/// `mt-cli log` forwards only the flags it was given, so a bare call gets the
/// server's own defaults rather than a second copy of them kept here.
final class LogCommandTests: XCTestCase {
    func testABareCallSendsNoQuery() throws {
        XCTAssertEqual(try LogCommand.parse([]).requestPath, "/log")
    }

    func testSinceAndLimitAreForwarded() throws {
        let command = try LogCommand.parse(["--since", "120", "--limit", "50"])
        XCTAssertEqual(command.requestPath, "/log?since=120.0&limit=50")
    }

    func testEachFlagAloneIsForwardedAlone() throws {
        XCTAssertEqual(try LogCommand.parse(["--since", "1.5"]).requestPath, "/log?since=1.5")
        XCTAssertEqual(try LogCommand.parse(["--limit", "7"]).requestPath, "/log?limit=7")
    }

    func testTheRootCommandRoutesLogToIt() throws {
        let command = try XCTUnwrap(MTCLI.parseAsRoot(["log", "--limit", "3"]) as? LogCommand)
        XCTAssertEqual(command.requestPath, "/log?limit=3")
    }

    func testValuesTheServerWouldRefuseAreRejectedHere() {
        for arguments in [["--since=-1"], ["--since", "inf"], ["--since", "nan"], ["--limit", "0"], ["--limit=-2"], ["--limit", "many"]] {
            XCTAssertThrowsError(try LogCommand.parse(arguments), "\(arguments)")
        }
    }
}
