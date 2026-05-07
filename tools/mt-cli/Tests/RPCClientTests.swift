@testable import mt_cli
import XCTest

final class RPCClientTests: XCTestCase {
    func testDefaultTokenURLPointsAtAppDataDir() {
        let path = RPCClient.defaultTokenURL.path
        XCTAssertTrue(path.contains("MeetingTranscriber"))
        XCTAssertTrue(path.hasSuffix(".rpc-token"))
    }

    func testDefaultBaseURLIsLoopback() {
        XCTAssertEqual(RPCClient.defaultBaseURL.host, "127.0.0.1")
        XCTAssertEqual(RPCClient.defaultBaseURL.port, 9876)
    }

    func testMissingTokenErrorMessageMentionsEnvVar() {
        let err = RPCClient.RPCError.missingToken(URL(fileURLWithPath: "/tmp/nope"))
        XCTAssertTrue(err.description.contains("MEETINGTRANSCRIBER_DEBUG_RPC"))
    }

    func testAppNotRunningErrorMessageMentionsURL() {
        let err = RPCClient.RPCError.appNotRunning(RPCClient.defaultBaseURL)
        XCTAssertTrue(err.description.contains("127.0.0.1:9876"))
    }

    // MARK: - M7: HTTP timeouts

    /// A wedged server must not hang the CLI forever. The default per-request
    /// timeout has to be short enough for a human to notice, long enough that
    /// a slow `/state` snapshot doesn't false-positive.
    func testRequestTimeoutIsBounded() {
        XCTAssertLessThanOrEqual(RPCClient.requestTimeoutSeconds, 10)
        XCTAssertGreaterThan(RPCClient.requestTimeoutSeconds, 0)
    }

    /// `/screenshot` renders a window image and can legitimately take longer
    /// than `/state`; it gets its own bound, also bounded.
    func testScreenshotTimeoutIsBounded() {
        XCTAssertLessThanOrEqual(RPCClient.screenshotTimeoutSeconds, 30)
        XCTAssertGreaterThanOrEqual(
            RPCClient.screenshotTimeoutSeconds, RPCClient.requestTimeoutSeconds,
            "screenshot must allow at least the default per-request budget",
        )
    }
}
