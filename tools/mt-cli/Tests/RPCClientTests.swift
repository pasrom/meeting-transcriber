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

    /// The request target (path + query) must reach the server intact. The URL
    /// is built with `URL(string:relativeTo:)`, not `appendingPathComponent`,
    /// which would percent-encode the `?` and break `/ui/tree?window=…`.
    func testGetPreservesQueryStringInRequestTarget() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = SilentConnectionHolder()
        let captured = RequestLineBox()
        listener.newConnectionHandler = { connection in
            held.add(connection)
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    captured.set(text.components(separatedBy: "\r\n").first ?? "")
                }
                // Reply so the client's await returns; capture already happened.
                let resp = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
            }
        }

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

        _ = try await client.get("/ui/tree?window=settings")

        XCTAssertEqual(captured.value, "GET /ui/tree?window=settings HTTP/1.1")
    }

    /// The confirm-browser-consent command posts a Bool payload; it must
    /// serialize as a JSON boolean (`true`), not the integer `1`, so the
    /// server's `ConsentPayload { granted: Bool }` decodes it. Captures the
    /// request body off a fake server and asserts the exact bytes.
    func testPostSerializesBoolPayloadAsJSONBoolean() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = SilentConnectionHolder()
        let captured = RequestLineBox()
        listener.newConnectionHandler = { connection in
            held.add(connection)
            connection.start(queue: .global())
            // URLSession delivers the POST body in a TCP segment after the
            // headers, so accumulate until the full Content-Length body arrives.
            drainRequestBody(connection, into: captured)
        }

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

        _ = try await client.post("/action/confirmBrowserConsent", json: ["granted": true])

        XCTAssertEqual(captured.value, #"{"granted":true}"#)
    }
}

/// Recursively receive from `connection`, accumulating bytes until the full
/// HTTP request body (per Content-Length) has arrived, then store the body in
/// `box` and reply 200. URLSession splits headers and body across TCP segments,
/// so a single receive can't see the POST body.
private func drainRequestBody(_ connection: NWConnection, into box: RequestLineBox, acc: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        var buffer = acc
        if let data { buffer.append(data) }
        // Failable decode: a partial UTF-8 sequence at a TCP segment boundary
        // yields nil, so keep accumulating rather than corrupting the body.
        guard let text = String(bytes: buffer, encoding: .utf8) else {
            drainRequestBody(connection, into: box, acc: buffer)
            return
        }
        if let sep = text.range(of: "\r\n\r\n") {
            let header = String(text[..<sep.lowerBound])
            let body = String(text[sep.upperBound...])
            let expected = header
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            if body.utf8.count >= expected {
                box.set(body)
                let resp = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
        }
        drainRequestBody(connection, into: box, acc: buffer)
    }
}

/// Thread-safe single-shot box for the request line captured by the fake
/// server in `testGetPreservesQueryStringInRequestTarget`.
private final class RequestLineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        stored = line
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
