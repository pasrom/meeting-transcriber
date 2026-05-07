#if !APPSTORE
    @testable import MeetingTranscriber
    import Network
    import XCTest

    /// Real socket roundtrips: build a server, hit it via URLSession on the
    /// OS-assigned port, assert the response. Catches what the unit tests
    /// can't — actual NWListener wiring, header bytes on the wire, the
    /// receive() loop's framing logic.
    @MainActor
    final class DebugRPCServerIntegrationTests: XCTestCase {
        private static let testToken = "integration-token-deadbeef"
        private var server: DebugRPCServer?

        override func setUp() async throws {
            try await super.setUp()
            server = nil
        }

        override func tearDown() async throws {
            // Listener cancellation is fire-and-forget — give Network.framework
            // a beat to release the port before the next test binds.
            server = nil
            try await Task.sleep(for: .milliseconds(50))
            try await super.tearDown()
        }

        // MARK: - Setup

        private func startServer(snapshot: RPCStateSnapshot = .empty) async throws -> URL {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { snapshot }
            self.server = server
            server.start()
            // Wait for the listener's stateUpdateHandler to populate boundPort.
            for _ in 0 ..< 50 {
                if let port = server.boundPort,
                   let url = URL(string: "http://127.0.0.1:\(port)") {
                    return url
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw XCTestError(.timeoutWhileWaiting)
        }

        private func request(_ method: String, _ url: URL, headers: [String: String] = [:]) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = method
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            return req
        }

        private var authHeader: [String: String] {
            ["Authorization": "Bearer \(Self.testToken)"]
        }

        // MARK: - Tests

        func testHealthzRoundtripWithAuth() async throws {
            let base = try await startServer()
            let (data, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("healthz"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "ok\n")
        }

        func testMissingAuthReturns401() async throws {
            let base = try await startServer()
            let (_, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("healthz")),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }

        func testBrowserOriginReturns403() async throws {
            let base = try await startServer()
            var headers = authHeader
            headers["Origin"] = "http://evil.example"
            let (_, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("healthz"), headers: headers),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        }

        func testStateReturnsValidJSON() async throws {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(isProcessing: true, activeJobCount: 2, waitingJobCount: 0, pendingNamingJobCount: 1),
                speakerDB: .init(count: 7, recentNames: ["Alice"], knownSpeakerNames: ["Alice"]),
                pendingNamingJobs: [],
            )
            let base = try await startServer(snapshot: snapshot)
            let (data, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("state"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(RPCStateSnapshot.self, from: data)
            XCTAssertEqual(decoded.pipeline.activeJobCount, 2)
            XCTAssertEqual(decoded.speakerDB.count, 7)
        }

        func testOpenSettingsReturns200() async throws {
            // The notification fires into a test process with no SwiftUI
            // scenes, so it's a no-op; we only verify the route plumbs through
            // and the response is well-formed.
            let base = try await startServer()
            let (data, response) = try await URLSession.shared.data(
                for: request("POST", base.appendingPathComponent("action/openSettings"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "ok\n")
        }

        func testUnknownPathReturns404() async throws {
            let base = try await startServer()
            let (_, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("nope"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }

        func testScreenshotIdleReturns503() async throws {
            // No SwiftUI scene → no window meets minWindowAreaPx → 503.
            let base = try await startServer()
            let (_, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("screenshot"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        }

        // MARK: - M6: Host header allowlist (raw-socket)

        /// `URLRequest.setValue(_:forHTTPHeaderField: "Host")` is silently
        /// ignored by URLSession — Host is reserved. To exercise the
        /// server's Host check we have to write the request bytes ourselves
        /// over a TCP socket.
        ///
        /// This test sends a syntactically valid HTTP/1.1 request with
        /// `Host: evil.example` and a valid bearer; expects a 403 from the
        /// route guard (not a 401 — auth would pass, Host comes first).
        func testRawSocketForeignHostReturns403() async throws {
            let base = try await startServer()
            guard let port = base.port else { XCTFail("no port"); return }

            let raw =
                "GET /healthz HTTP/1.1\r\n" +
                "Host: evil.example\r\n" +
                "Authorization: Bearer \(Self.testToken)\r\n" +
                "\r\n"

            let response = try await sendRawHTTP(toPort: UInt16(port), bytes: Data(raw.utf8))
            let firstLine = response.split(separator: "\n").first ?? ""
            XCTAssertTrue(
                firstLine.contains("403"),
                "Expected 403 for foreign Host, got: \(firstLine)",
            )
        }

        /// Same shape, but the Host is loopback — must pass the allowlist
        /// and reach 200. Confirms we didn't accidentally close the door
        /// on legitimate clients.
        func testRawSocketLoopbackHostReturns200() async throws {
            let base = try await startServer()
            guard let port = base.port else { XCTFail("no port"); return }

            let raw =
                "GET /healthz HTTP/1.1\r\n" +
                "Host: 127.0.0.1:\(port)\r\n" +
                "Authorization: Bearer \(Self.testToken)\r\n" +
                "\r\n"

            let response = try await sendRawHTTP(toPort: UInt16(port), bytes: Data(raw.utf8))
            let firstLine = response.split(separator: "\n").first ?? ""
            XCTAssertTrue(
                firstLine.contains("200"),
                "Expected 200 for loopback Host, got: \(firstLine)",
            )
        }

        /// Open a TCP connection to `port`, write `bytes`, read response,
        /// return as String. Used by the raw-socket Host tests because
        /// URLSession reserves the `Host` header.
        private func sendRawHTTP(toPort port: UInt16, bytes: Data) async throws -> String {
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port) ?? .any,
                using: .tcp,
            )
            return try await withCheckedThrowingContinuation { continuation in
                let resumer = OneShotResumer(continuation, connection: connection)
                connection.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        resumer.fail(error)
                    }
                }
                connection.start(queue: .global())
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error {
                        resumer.fail(error)
                        return
                    }
                    receiveUntilHeadersComplete(connection: connection, resumer: resumer)
                })
            }
        }
    }

    /// Read repeatedly until the server's status line + headers are in,
    /// then resume with the accumulated bytes as a UTF-8 string. The
    /// debug RPC keeps the connection open after responding, so we use
    /// `\r\n\r\n` as the "headers ended" marker rather than waiting for
    /// `isComplete`. File-scope (non-isolated) so it can be called from
    /// the Network.framework callbacks that run off the main actor.
    private func receiveUntilHeadersComplete(
        connection: NWConnection, resumer: OneShotResumer, accumulated: Data = Data(),
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, _ in
            var buffer = accumulated
            if let data { buffer.append(data) }
            let body = String(data: buffer, encoding: .utf8) ?? ""
            if isComplete || body.contains("\r\n\r\n") {
                resumer.succeed(body)
                return
            }
            receiveUntilHeadersComplete(connection: connection, resumer: resumer, accumulated: buffer)
        }
    }

    /// Resumes a `CheckedContinuation` exactly once and cancels the underlying
    /// connection. Multiple callbacks (state-failed, send-error, receive-error
    /// or receive-success) can race; without this the second resume would
    /// trip the runtime check.
    private final class OneShotResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<String, any Error>
        private let connection: NWConnection

        init(_ continuation: CheckedContinuation<String, any Error>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func succeed(_ body: String) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(returning: body)
            connection.cancel()
        }

        func fail(_ error: any Error) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(throwing: error)
            connection.cancel()
        }
    }
#endif
