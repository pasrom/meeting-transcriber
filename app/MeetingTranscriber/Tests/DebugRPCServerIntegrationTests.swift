#if !APPSTORE
    @testable import MeetingTranscriber
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
                speakerDB: .init(count: 7, recentNames: ["Alice"]),
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
    }
#endif
