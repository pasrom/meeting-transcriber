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
}
