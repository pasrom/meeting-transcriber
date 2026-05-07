#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    final class DebugRPCServerTests: XCTestCase {
        private static let testToken = "testtoken1234"
        private static let authHeaders: [String: String] = ["authorization": "Bearer \(testToken)"]

        // MARK: - HTTPRequest parsing

        func testParseGet() {
            let raw = Data("GET /state HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
            let req = HTTPRequest.parse(raw)
            XCTAssertEqual(req?.method, "GET")
            XCTAssertEqual(req?.path, "/state")
            XCTAssertEqual(req?.body.count, 0)
            XCTAssertEqual(req?.headers["host"], "localhost")
        }

        func testParsePostWithBody() {
            let raw = Data("POST /action/click HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"id\":\"foo\"}\n".utf8)
            let req = HTTPRequest.parse(raw)
            XCTAssertEqual(req?.method, "POST")
            XCTAssertEqual(req?.path, "/action/click")
            XCTAssertEqual(req?.body.count, 13)
        }

        func testParseExtractsHeadersLowercase() {
            let raw = Data(
                "GET / HTTP/1.1\r\nOrigin: http://evil.example\r\nAuthorization: Bearer x\r\n\r\n".utf8,
            )
            let req = HTTPRequest.parse(raw)
            XCTAssertEqual(req?.headers["origin"], "http://evil.example")
            XCTAssertEqual(req?.headers["authorization"], "Bearer x")
        }

        func testParseIncompleteHeaderReturnsNil() {
            // No \r\n\r\n yet — parse must wait.
            let raw = Data("GET /state HTTP/1.1\r\n".utf8)
            XCTAssertNil(HTTPRequest.parse(raw))
        }

        func testParseIncompleteBodyReturnsNil() {
            // Content-Length says 50 but only 5 body bytes present.
            let raw = Data("POST /x HTTP/1.1\r\nContent-Length: 50\r\n\r\nhello".utf8)
            XCTAssertNil(HTTPRequest.parse(raw))
        }

        // MARK: - HTTPResponse serialization

        func testResponseShape() {
            let body = Data("{}".utf8)
            let resp = HTTPResponse.ok(body: body, contentType: "application/json")
            let raw = resp.serialize()
            let s = String(data: raw, encoding: .utf8) ?? ""
            XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
            XCTAssertTrue(s.contains("Content-Type: application/json\r\n"))
            XCTAssertTrue(s.contains("Content-Length: 2\r\n"))
            XCTAssertTrue(s.hasSuffix("\r\n\r\n{}"))
        }

        func testNotFoundShape() {
            let resp = HTTPResponse.notFound()
            let s = String(data: resp.serialize(), encoding: .utf8) ?? ""
            XCTAssertTrue(s.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
            XCTAssertTrue(s.contains("Content-Length: 0\r\n"))
        }

        func testUnauthorizedShape() {
            let s = String(data: HTTPResponse.unauthorized().serialize(), encoding: .utf8) ?? ""
            XCTAssertTrue(s.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        }

        func testForbiddenShape() {
            let s = String(data: HTTPResponse.forbidden().serialize(), encoding: .utf8) ?? ""
            XCTAssertTrue(s.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        }

        // MARK: - Routing

        @MainActor
        func testRouteState() {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(isProcessing: false, activeJobCount: 1, waitingJobCount: 0, pendingNamingJobCount: 0),
                speakerDB: .init(count: 5, recentNames: ["Speaker A"], knownSpeakerNames: ["Speaker A"]),
                pendingNamingJobs: [],
            )
            let server = DebugRPCServer(port: 0, token: Self.testToken) { snapshot }
            let response = server.route(authedRequest(method: "GET", path: "/state"))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.contentType, "application/json")
            let decoded = try? JSONDecoder().decode(RPCStateSnapshot.self, from: response.body)
            XCTAssertEqual(decoded?.pipeline.activeJobCount, 1)
            XCTAssertEqual(decoded?.speakerDB.count, 5)
        }

        @MainActor
        func testRouteHealthz() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = server.route(authedRequest(method: "GET", path: "/healthz"))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(String(data: response.body, encoding: .utf8), "ok\n")
        }

        @MainActor
        func testRouteOpenSettingsReturnsOk() {
            // The actual AppKit selector is a no-op in the test harness (no
            // Settings scene declared); we only verify the route plumbs through.
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = server.route(authedRequest(method: "POST", path: "/action/openSettings"))
            XCTAssertEqual(response.status, 200)
        }

        @MainActor
        func testRouteCloseSettingsReturnsOk() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = server.route(authedRequest(method: "POST", path: "/action/closeSettings"))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(String(data: response.body, encoding: .utf8), "ok\n")
        }

        @MainActor
        func testRouteScreenshotNoWindowReturns503() {
            // Tests run headless — NSApp has no visible window, so the
            // capture helper returns nil and the route maps to 503.
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = server.route(authedRequest(method: "GET", path: "/screenshot"))
            XCTAssertEqual(response.status, 503)
        }

        @MainActor
        func testRouteUnknown() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = server.route(authedRequest(method: "GET", path: "/nope"))
            XCTAssertEqual(response.status, 404)
        }

        // MARK: - Security

        @MainActor
        func testRouteRejectsMissingAuth() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = server.route(HTTPRequest(method: "GET", path: "/state"))
            XCTAssertEqual(response.status, 401)
        }

        @MainActor
        func testRouteRejectsWrongToken() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            let response = server.route(HTTPRequest(
                method: "GET", path: "/state",
                headers: ["authorization": "Bearer nope"],
            ))
            XCTAssertEqual(response.status, 401)
        }

        @MainActor
        func testRouteRejectsNonEmptyOrigin() {
            // Browser CSRF: page on https://evil.example sends Origin.
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            var headers = Self.authHeaders
            headers["origin"] = "http://evil.example"
            let response = server.route(HTTPRequest(method: "GET", path: "/state", headers: headers))
            XCTAssertEqual(response.status, 403)
        }

        @MainActor
        func testRouteAcceptsNullOrigin() {
            // Some user agents send literal "null" for sandboxed/file:// contexts —
            // treat as absent so curl/native tools always work.
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            var headers = Self.authHeaders
            headers["origin"] = "null"
            let response = server.route(HTTPRequest(method: "GET", path: "/healthz", headers: headers))
            XCTAssertEqual(response.status, 200)
        }

        // MARK: - Enabled gate

        func testEnabledFollowsEnvVar() {
            // The runtime env value is whatever launched this test process —
            // assert the API works rather than a specific value.
            let value = ProcessInfo.processInfo.environment[DebugRPCServer.envVar]
            XCTAssertEqual(DebugRPCServer.enabled, value == "1")
        }

        // MARK: - Lifecycle

        @MainActor
        func testStopIsIdempotent() {
            let server = DebugRPCServer(port: 0, token: Self.testToken) { .empty }
            // Safe to call before start.
            server.stop()
            server.stop()
            // Safe to call after start.
            server.start()
            server.stop()
            server.stop()
        }

        // MARK: - Token persistence

        func testLoadOrCreateTokenIsStableAndChmod600() throws {
            // We can't easily redirect AppPaths in a test, so just assert the
            // function returns a 64-hex string and is idempotent.
            let first = DebugRPCServer.loadOrCreateToken()
            let second = DebugRPCServer.loadOrCreateToken()
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.count, 64)
            XCTAssertTrue(first.allSatisfy(\.isHexDigit))

            let attrs = try FileManager.default.attributesOfItem(atPath: DebugRPCServer.tokenFileURL.path)
            let perms = (attrs[.posixPermissions] as? Int) ?? -1
            XCTAssertEqual(perms, 0o600)
        }

        // MARK: - Speaker DB action routes

        @MainActor
        func testRouteRenameSpeakerCallsActionAndReturnsOK() throws {
            let stub = StubSpeakerActions()
            stub.renameOutcome = .ok
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"from":"Old","to":"New"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/renameSpeaker", body: body))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(stub.renameCalls.count, 1)
            XCTAssertEqual(stub.renameCalls.first?.0, "Old")
            XCTAssertEqual(stub.renameCalls.first?.1, "New")
            let decoded = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
            XCTAssertEqual(decoded?["outcome"], "ok")
        }

        @MainActor
        func testRouteRenameSpeakerNotFoundReturns404() {
            let stub = StubSpeakerActions()
            stub.renameOutcome = .notFound
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"from":"Missing","to":"Whatever"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/renameSpeaker", body: body))
            XCTAssertEqual(response.status, 404)
        }

        @MainActor
        func testRouteRenameSpeakerCollisionReturnsMerged() throws {
            let stub = StubSpeakerActions()
            stub.renameOutcome = .merged
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"from":"A","to":"B"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/renameSpeaker", body: body))
            XCTAssertEqual(response.status, 200)
            let decoded = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
            XCTAssertEqual(decoded?["outcome"], "merged")
        }

        @MainActor
        func testRouteRenameSpeakerInvalidJSONReturns400() {
            let stub = StubSpeakerActions()
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data("{not json".utf8)
            let response = server.route(authedJSONRequest(path: "/action/renameSpeaker", body: body))
            XCTAssertEqual(response.status, 400)
        }

        @MainActor
        func testRouteRenameSpeakerMissingFieldReturns400() {
            let stub = StubSpeakerActions()
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"from":"OnlyThis"}"#.utf8) // missing "to"
            let response = server.route(authedJSONRequest(path: "/action/renameSpeaker", body: body))
            XCTAssertEqual(response.status, 400)
            XCTAssertTrue(stub.renameCalls.isEmpty)
        }

        @MainActor
        func testRouteDeleteSpeakerCallsActionAndReturnsOK() {
            let stub = StubSpeakerActions()
            stub.deleteOutcome = .ok
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"name":"Doomed"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/deleteSpeaker", body: body))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(stub.deleteCalls, ["Doomed"])
        }

        @MainActor
        func testRouteDeleteSpeakerNotFoundReturns404() {
            let stub = StubSpeakerActions()
            stub.deleteOutcome = .notFound
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"name":"Ghost"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/deleteSpeaker", body: body))
            XCTAssertEqual(response.status, 404)
        }

        @MainActor
        func testRouteMergeSpeakersCallsActionAndReturnsOK() {
            let stub = StubSpeakerActions()
            stub.mergeOutcome = .ok
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"from":"A","into":"B"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/mergeSpeakers", body: body))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(stub.mergeCalls.first?.0, "A")
            XCTAssertEqual(stub.mergeCalls.first?.1, "B")
        }

        @MainActor
        func testRouteMergeSpeakersNotFoundReturns404() {
            let stub = StubSpeakerActions()
            stub.mergeOutcome = .notFound
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"from":"X","into":"Y"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/mergeSpeakers", body: body))
            XCTAssertEqual(response.status, 404)
        }

        @MainActor
        func testRouteSeedSpeakerCallsActionAndReturnsOK() {
            let stub = StubSpeakerActions()
            stub.seedOutcome = .ok
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"name":"NewSeed"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/seedSpeaker", body: body))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(stub.seedCalls, ["NewSeed"])
        }

        @MainActor
        func testRouteSeedSpeakerInvalidJSONReturns400() {
            let stub = StubSpeakerActions()
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"wrong":"shape"}"#.utf8)
            let response = server.route(authedJSONRequest(path: "/action/seedSpeaker", body: body))
            XCTAssertEqual(response.status, 400)
        }

        @MainActor
        func testRouteStateExposesKnownSpeakerNames() throws {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(isProcessing: false, activeJobCount: 0, waitingJobCount: 0, pendingNamingJobCount: 0),
                speakerDB: .init(count: 2, recentNames: ["Alice", "Bob"], knownSpeakerNames: ["Alice", "Bob"]),
                pendingNamingJobs: [],
            )
            let server = DebugRPCServer(port: 0, token: Self.testToken) { snapshot }
            let response = server.route(authedRequest(method: "GET", path: "/state"))
            let decoded = try JSONDecoder().decode(RPCStateSnapshot.self, from: response.body)
            XCTAssertEqual(decoded.speakerDB.knownSpeakerNames, ["Alice", "Bob"])
        }

        @MainActor
        func testRouteSpeakerActionsRejectMissingAuth() {
            let stub = StubSpeakerActions()
            let server = DebugRPCServer(
                port: 0, token: Self.testToken,
                snapshot: { .empty }, speakerActions: stub.actions(),
            )
            let body = Data(#"{"from":"A","to":"B"}"#.utf8)
            // Missing Authorization header.
            let request = HTTPRequest(
                method: "POST", path: "/action/renameSpeaker",
                headers: ["content-type": "application/json"], body: body,
            )
            XCTAssertEqual(server.route(request).status, 401)
        }

        // MARK: - Snapshot JSON

        func testSnapshotEncodesPretty() throws {
            let snap = RPCStateSnapshot.empty
            let data = try snap.jsonData()
            let s = String(data: data, encoding: .utf8) ?? ""
            // Pretty-printed → contains newlines + sorted keys.
            XCTAssertTrue(s.contains("\n"))
            XCTAssertTrue(s.contains("\"pipeline\""))
            XCTAssertTrue(s.contains("\"speakerDB\""))
        }

        // MARK: - Helpers

        private func authedRequest(method: String, path: String, body: Data = Data()) -> HTTPRequest {
            HTTPRequest(method: method, path: path, headers: Self.authHeaders, body: body)
        }

        private func authedJSONRequest(path: String, body: Data) -> HTTPRequest {
            var headers = Self.authHeaders
            headers["content-type"] = "application/json"
            return HTTPRequest(method: "POST", path: path, headers: headers, body: body)
        }
    }

    /// Stub that records calls and returns canned outcomes per action.
    /// Used by routing tests to verify the request → closure → response wiring.
    final class StubSpeakerActions {
        private(set) var renameCalls: [(String, String)] = []
        private(set) var deleteCalls: [String] = []
        private(set) var mergeCalls: [(String, String)] = []
        private(set) var seedCalls: [String] = []
        var renameOutcome: SpeakerActionOutcome = .ok
        var deleteOutcome: SpeakerActionOutcome = .ok
        var mergeOutcome: SpeakerActionOutcome = .ok
        var seedOutcome: SpeakerActionOutcome = .ok

        func actions() -> SpeakerDBActions {
            SpeakerDBActions(
                rename: { [weak self] from, to in
                    self?.renameCalls.append((from, to))
                    return self?.renameOutcome ?? .invalid
                },
                delete: { [weak self] name in
                    self?.deleteCalls.append(name)
                    return self?.deleteOutcome ?? .invalid
                },
                merge: { [weak self] from, into in
                    self?.mergeCalls.append((from, into))
                    return self?.mergeOutcome ?? .invalid
                },
                seed: { [weak self] name in
                    self?.seedCalls.append(name)
                    return self?.seedOutcome ?? .invalid
                },
            )
        }
    }

    // MARK: - M1: constant-time auth compare

    extension DebugRPCServerTests {
        /// Equal strings compare equal. Boring sanity baseline.
        func testConstantTimeEqualsAcceptsExactMatch() {
            XCTAssertTrue(
                DebugRPCServer.constantTimeEquals(
                    "Bearer abcdef1234567890",
                    "Bearer abcdef1234567890",
                ),
            )
        }

        /// First-byte mismatch must still walk the full string — that's the
        /// whole point. Correctness check: non-equal returns false regardless
        /// of which byte differs.
        func testConstantTimeEqualsRejectsFirstByteMismatch() {
            XCTAssertFalse(
                DebugRPCServer.constantTimeEquals(
                    "X" + "earer abcdef1234567890",
                    "Bearer abcdef1234567890",
                ),
            )
        }

        func testConstantTimeEqualsRejectsLastByteMismatch() {
            XCTAssertFalse(
                DebugRPCServer.constantTimeEquals(
                    "Bearer abcdef123456789X",
                    "Bearer abcdef1234567890",
                ),
            )
        }

        /// Different lengths are unconditionally not-equal — but the
        /// implementation must not short-circuit at the length check (which
        /// would reveal length via timing). We can't assert the timing
        /// directly, only the correctness.
        func testConstantTimeEqualsRejectsLengthMismatch() {
            XCTAssertFalse(
                DebugRPCServer.constantTimeEquals("Bearer abc", "Bearer abcdef"),
            )
            XCTAssertFalse(
                DebugRPCServer.constantTimeEquals("Bearer abcdef", "Bearer abc"),
            )
        }

        func testConstantTimeEqualsHandlesEmptyStrings() {
            XCTAssertTrue(DebugRPCServer.constantTimeEquals("", ""))
            XCTAssertFalse(DebugRPCServer.constantTimeEquals("", "a"))
        }
    }

    // MARK: - M6: Host header allowlist

    extension DebugRPCServerTests {
        func testIsHostAllowedAcceptsLoopback() {
            XCTAssertTrue(DebugRPCServer.isHostAllowed("127.0.0.1:9876", port: 9876))
            XCTAssertTrue(DebugRPCServer.isHostAllowed("localhost:9876", port: 9876))
        }

        /// Missing Host header passes — old HTTP/1.0 clients and our own
        /// server's startup probes don't always set one. Defense-in-depth on
        /// top of the loopback bind + bearer check, not a primary gate.
        func testIsHostAllowedAcceptsEmpty() {
            XCTAssertTrue(DebugRPCServer.isHostAllowed("", port: 9876))
        }

        /// DNS-rebinding payload: attacker's site resolves a hostname they
        /// control to 127.0.0.1, then the browser sends `Host: evil.example`.
        /// Loopback bind doesn't catch this; the Host header does.
        func testIsHostAllowedRejectsForeignHostname() {
            XCTAssertFalse(DebugRPCServer.isHostAllowed("evil.example:9876", port: 9876))
            XCTAssertFalse(DebugRPCServer.isHostAllowed("rebind.attacker.com", port: 9876))
        }

        /// Wrong-port spoof — the bearer is the real defense, but reject
        /// anyway so a misconfigured proxy can't accidentally talk to us.
        func testIsHostAllowedRejectsWrongPort() {
            XCTAssertFalse(DebugRPCServer.isHostAllowed("127.0.0.1:8080", port: 9876))
        }

        func testIsHostAllowedAcceptsHostWithoutPort() {
            // RFC 7230: Host MAY omit port when it's the default. Our default
            // is 9876, never 80/443, so a bare "127.0.0.1" without port is
            // ambiguous — accept it as loopback rather than fail-closed.
            XCTAssertTrue(DebugRPCServer.isHostAllowed("127.0.0.1", port: 9876))
            XCTAssertTrue(DebugRPCServer.isHostAllowed("localhost", port: 9876))
        }
    }
#endif
