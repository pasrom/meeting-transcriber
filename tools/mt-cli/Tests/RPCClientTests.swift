@testable import mt_cli
import Network
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

    /// Behaviour-level: against a server that accepts the connection but
    /// never sends bytes back, `client.get` must time out instead of
    /// hanging. Catches a wiring regression that the contract test above
    /// can't see (e.g. `URLRequest.timeoutInterval` removed, custom
    /// `URLSessionConfiguration` overriding the per-request value, etc.).
    func testGetTimesOutAgainstSilentServer() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        // Holds incoming connections without writing — keeps a strong ref so
        // the connection isn't torn down before URLSession's timeout fires.
        let held = SilentConnectionHolder()
        listener.newConnectionHandler = { connection in
            held.add(connection)
            connection.start(queue: .global())
            // Don't read or write; the client is waiting for our response.
        }

        // The listener's `.port` is the requested port (.any → 0) until the
        // `.ready` state fires with the OS-assigned port. Wait for that.
        let portReady = XCTestExpectation(description: "listener bound")
        let assignedPort = OSPortBox()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue {
                assignedPort.set(port)
                portReady.fulfill()
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }

        await fulfillment(of: [portReady], timeout: 2)
        let port = try XCTUnwrap(assignedPort.value)
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            XCTFail("could not build URL")
            return
        }
        let client = RPCClient(baseURL: baseURL, token: "test-token")

        let start = Date()
        let timeout: TimeInterval = 1
        do {
            _ = try await client.get("/healthz", timeout: timeout)
            XCTFail("expected request to time out, got data")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            // The request must have actually taken roughly the configured
            // timeout — a quick bail-out (e.g. connection refused, missing
            // wiring of `req.timeoutInterval`) finishes in milliseconds and
            // means the timeout knob isn't being honoured.
            XCTAssertGreaterThanOrEqual(
                elapsed, timeout * 0.7,
                "Client gave up too fast (elapsed=\(elapsed)s, timeout=\(timeout)s)" +
                    " — connection probably failed before timeout could fire." +
                    " Error was: \(error)",
            )
            XCTAssertLessThan(
                elapsed, timeout * 4,
                "Client did not honour timeout: elapsed=\(elapsed)s, timeout=\(timeout)s",
            )
        }
    }
}

/// Thread-safe single-shot box for the OS-assigned listener port — written
/// from the listener's stateUpdateHandler queue, read from the test actor.
private final class OSPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt16?
    var value: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        stored = port
    }
}

/// Thread-safe holder that keeps `NWConnection` instances alive for the
/// duration of a test. Without strong references the system tears the
/// connection down before URLSession's timeout has a chance to fire.
private final class SilentConnectionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    func add(_ connection: NWConnection) {
        lock.lock(); defer { lock.unlock() }
        connections.append(connection)
    }
}
