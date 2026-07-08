#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Unit tests for `HTTPRequest.parse` — the minimal HTTP/1.1 request parser
    /// backing `DebugRPCServer`. Split out of `DebugRPCServerTests` so the parser
    /// tests live next to the type under test and the server test class stays
    /// within its body-length budget.
    final class HTTPRequestTests: XCTestCase {
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

        func testParseNegativeContentLengthReturnsNil() {
            // A negative Content-Length must be rejected outright. Without a
            // guard, `bodyStart ..< bodyStart + contentLength` builds a Range
            // whose lowerBound exceeds its upperBound and traps — aborting the
            // process before the origin/token checks ever run.
            let raw = Data("GET /healthz HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
            XCTAssertNil(HTTPRequest.parse(raw))
        }
    }
#endif
