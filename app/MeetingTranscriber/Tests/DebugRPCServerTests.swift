#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    final class DebugRPCServerTests: XCTestCase {
        // MARK: - HTTPRequest parsing

        func testParseGet() {
            let raw = Data("GET /state HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
            let req = HTTPRequest.parse(raw)
            XCTAssertEqual(req?.method, "GET")
            XCTAssertEqual(req?.path, "/state")
            XCTAssertEqual(req?.body.count, 0)
        }

        func testParsePostWithBody() {
            let raw = Data("POST /action/click HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"id\":\"foo\"}\n".utf8)
            let req = HTTPRequest.parse(raw)
            XCTAssertEqual(req?.method, "POST")
            XCTAssertEqual(req?.path, "/action/click")
            XCTAssertEqual(req?.body.count, 13)
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

        // MARK: - Routing

        @MainActor
        func testRouteState() {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(isProcessing: false, activeJobCount: 1, waitingJobCount: 0, pendingNamingJobCount: 0),
                speakerDB: .init(count: 5, recentNames: ["Speaker A"]),
                pendingNamingJobs: [],
            )
            let server = DebugRPCServer(port: 0) { snapshot }
            let response = server.route(HTTPRequest(method: "GET", path: "/state", body: Data()))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.contentType, "application/json")
            let decoded = try? JSONDecoder().decode(RPCStateSnapshot.self, from: response.body)
            XCTAssertEqual(decoded?.pipeline.activeJobCount, 1)
            XCTAssertEqual(decoded?.speakerDB.count, 5)
        }

        @MainActor
        func testRouteHealthz() {
            let server = DebugRPCServer(port: 0) { .empty }
            let response = server.route(HTTPRequest(method: "GET", path: "/healthz", body: Data()))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(String(data: response.body, encoding: .utf8), "ok\n")
        }

        @MainActor
        func testRouteUnknown() {
            let server = DebugRPCServer(port: 0) { .empty }
            let response = server.route(HTTPRequest(method: "GET", path: "/nope", body: Data()))
            XCTAssertEqual(response.status, 404)
        }

        // MARK: - Enabled gate

        func testEnabledFollowsEnvVar() {
            // The runtime env value is whatever launched this test process —
            // assert the API works rather than a specific value.
            let value = ProcessInfo.processInfo.environment[DebugRPCServer.envVar]
            XCTAssertEqual(DebugRPCServer.enabled, value == "1")
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
    }
#endif
