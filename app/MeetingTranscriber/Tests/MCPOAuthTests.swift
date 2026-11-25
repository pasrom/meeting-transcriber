import Foundation
@testable import MeetingTranscriber
import XCTest
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@MainActor
final class MCPOAuthTests: XCTestCase {
    func testURLOnlySignInRegistersAndExchangesWithPKCEThenRotatesTokens() async throws {
        let fixture = OAuthFixture()
        let client = fixture.client
        let flow = try await client.begin(endpoint: fixture.resource, redirect: fixture.redirect, clientID: nil)
        let query = try XCTUnwrap(parts(of: flow.authorizationURL).queryItems)
        let authorization = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        XCTAssertEqual(flow.authorizationURL.host, "auth.example.test")
        XCTAssertEqual(authorization["resource"], fixture.resource.absoluteString)
        XCTAssertEqual(authorization["client_id"], "fixture-public-client")
        XCTAssertEqual(authorization["scope"], "tools:read files:read")
        XCTAssertEqual(authorization["code_challenge_method"], "S256")
        XCTAssertEqual(authorization["state"], flow.state)
        let digest = ContextDigest.sha256(Data(flow.verifier.utf8)).base64EncodedString()
        let challenge = digest.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(authorization["code_challenge"], challenge)
        XCTAssertFalse(flow.authorizationURL.absoluteString.contains(flow.verifier))

        let callback = try callbackURL(flow, [URLQueryItem(name: "code", value: "fixture+code&value")])
        let stored = try await client.finish(flow, code: flow.code(from: callback))
        XCTAssertEqual(stored.accessToken, "fixture-access-1")
        XCTAssertTrue(stored.needsRefresh(at: Date()))
        let refreshed = try await client.refresh(stored)
        XCTAssertEqual(refreshed.accessToken, "fixture-access-2")
        XCTAssertEqual(refreshed.refreshToken, "fixture-refresh-2")
        XCTAssertFalse(refreshed.needsRefresh(at: Date()))
        XCTAssertTrue(refreshed.matches(fixture.resource))

        let requests = await fixture.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            fixture.resource.absoluteString, fixture.protectedMetadata.absoluteString,
            "https://auth.example.test/.well-known/oauth-authorization-server/tenant",
            "https://auth.example.test/register", "https://auth.example.test/token", "https://auth.example.test/token",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let registration = try JSONDecoder().decode(ContextJSON.self, from: XCTUnwrap(requests[3].httpBody))
        XCTAssertEqual(registration["token_endpoint_auth_method"], .string("none"))
        XCTAssertEqual(registration["redirect_uris"], .array([.string(fixture.redirect.absoluteString)]))
        let exchange = try XCTUnwrap(String(bytes: XCTUnwrap(requests[4].httpBody), encoding: .utf8))
        XCTAssertTrue(exchange.contains("code=fixture%2Bcode%26value"))
        XCTAssertTrue(exchange.contains("code_verifier=\(flow.verifier)"))
        XCTAssertTrue(exchange.contains("resource=https%3A%2F%2Fmcp.example.test%2Fapi%2Fmcp"))
        let refresh = try XCTUnwrap(String(bytes: XCTUnwrap(requests[5].httpBody), encoding: .utf8))
        XCTAssertTrue(refresh.contains("grant_type=refresh_token"))
        XCTAssertTrue(refresh.contains("refresh_token=fixture%2Brefresh%261"))
    }

    func testPublishedClientMetadataNeedsNoUserClientID() async throws {
        let fixture = OAuthFixture(mode: .publishedClient)
        let client = fixture.client
        let flow = try await client.begin(endpoint: fixture.resource, redirect: fixture.redirect, clientID: nil)
        XCTAssertEqual(flow.clientID, "https://meetingtranscriber.app/mcp-oauth-client.json")
        let paths = await fixture.requests.compactMap { $0.url?.path }
        XCTAssertTrue(paths.contains("/mcp-oauth-client.json"))
        XCTAssertFalse(paths.contains("/register"))
    }

    func testUnavailablePublishedClientMetadataFallsBackToDynamicRegistration() async throws {
        let fixture = OAuthFixture(mode: .unpublishedClient)
        let client = fixture.client
        let flow = try await client.begin(endpoint: fixture.resource, redirect: fixture.redirect, clientID: nil)
        XCTAssertEqual(flow.clientID, "fixture-public-client")
        let paths = await fixture.requests.compactMap { $0.url?.path }
        XCTAssertEqual(Array(paths.suffix(2)), ["/mcp-oauth-client.json", "/register"])
    }

    func testWellKnownDiscoveryFallsBackForRegisteredPublicClient() async throws {
        let fixture = OAuthFixture(mode: .fallback)
        let client = fixture.client
        let flow = try await client.begin(endpoint: fixture.resource, redirect: fixture.redirect, clientID: "provided-client-id")
        XCTAssertEqual(flow.clientID, "provided-client-id")
        XCTAssertEqual(flow.metadata.scopes, "tools:read")
        let paths = await fixture.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, [
            "/api/mcp", "/.well-known/oauth-protected-resource/api/mcp", "/.well-known/oauth-protected-resource",
            "/.well-known/oauth-authorization-server/tenant", "/.well-known/openid-configuration/tenant",
            "/tenant/.well-known/openid-configuration",
        ])
    }

    func testDiscoveryRejectsWrongResourceIssuerInsecureTokenEndpointAndMissingPKCE() async {
        for (mode, expected) in [
            (OAuthFixture.Mode.wrongResource, MCPOAuthError.discovery), (.wrongIssuer, .discovery),
            (.insecureToken, .discovery), (.noPKCE, .pkce),
        ] {
            let fixture = OAuthFixture(mode: mode)
            do {
                _ = try await fixture.client.discover(endpoint: fixture.resource)
                XCTFail("Discovery accepted invalid metadata")
            } catch {
                XCTAssertEqual(error as? MCPOAuthError, expected)
            }
            let paths = await fixture.requests.compactMap { $0.url?.path }
            XCTAssertFalse(paths.contains("/register"))
            XCTAssertFalse(paths.contains("/token"))
        }
    }

    func testCallbackRejectsStateIssuerAndRedirectMismatch() async throws {
        let fixture = OAuthFixture()
        let client = fixture.client
        let flow = try await client.begin(endpoint: fixture.resource, redirect: fixture.redirect, clientID: "provided-client-id")
        let code = URLQueryItem(name: "code", value: "fixture-code")
        let wrongIssuer = URLQueryItem(name: "iss", value: "https://other.example.test/")
        let duplicateState = URLQueryItem(name: "state", value: flow.state)
        for fields in [[code, wrongIssuer], [code, duplicateState], [code, code]] {
            XCTAssertThrowsError(try flow.code(from: callbackURL(flow, fields))) { error in
                XCTAssertEqual(error as? MCPOAuthError, .callback)
            }
        }
        let callback = try callbackURL(flow, [code])
        var wrongRedirect = try parts(of: callback)
        wrongRedirect.port = 33333
        XCTAssertThrowsError(try flow.code(from: XCTUnwrap(wrongRedirect.url)))
        let denied = URLQueryItem(name: "error", value: "access_denied")
        XCTAssertThrowsError(try flow.code(from: callbackURL(flow, [denied]))) { error in
            XCTAssertEqual(error as? MCPOAuthError, .denied)
        }
        let wrongState = URLQueryItem(name: "state", value: "wrong-state")
        XCTAssertThrowsError(try flow.code(from: callbackURL(flow, [code], state: wrongState)))
    }

    func testExistingStaticConfigurationAndOAuthCredentialRedaction() throws {
        let fixture = OAuthFixture()
        let fields = try JSONDecoder().decode(MCPSecrets.self, from: Data(#"{"headers":{"X-Token":"fixture-api-key"},"environment":{}}"#.utf8))
        XCTAssertNil(fields.oauth)
        XCTAssertEqual(fields.values, ["fixture-api-key"])
        let source = MCPSource(location: "http://127.0.0.1:9876/mcp", allowLocalHTTP: true)
        let decoded = try JSONDecoder().decode(MCPSource.self, from: ContextJSON.encoded(source))
        XCTAssertFalse(decoded.usesOAuth)
        XCTAssertNotNil(decoded.endpoint)
        var oauthSource = decoded
        oauthSource.httpAuthentication = .oauth
        XCTAssertNil(oauthSource.endpoint)
        let credentials = MCPOAuthCredentials(
            resource: fixture.resource, tokenEndpoint: fixture.tokenEndpoint, clientID: "fixture-client",
            accessToken: "fixture-access-token", refreshToken: "fixture-refresh-token", expiresAt: nil,
        )
        XCTAssertFalse(try credentials.matches(XCTUnwrap(URL(string: "https://mcp.example.test/other"))))
        let saved = try JSONDecoder().decode(MCPSecrets.self, from: ContextJSON.encoded(MCPSecrets(oauth: credentials)))
        XCTAssertTrue(ContextDataSafety.containsSensitive("reference fixture-access-token", secrets: saved.values))
        XCTAssertTrue(ContextDataSafety.containsSensitive("reference fixture-refresh-token", secrets: saved.values))
        XCTAssertFalse(MCPOAuthClient.validBearer("fixture-token\n"))
    }

    #if os(macOS)
        func testBrowserCallbackIsReceivedOnLoopback() async throws {
            let listener = try MCPOAuthLoopback(port: 0)
            defer { listener.stop() }
            let redirect = try await listener.start()
            XCTAssertEqual(redirect.host, "127.0.0.1")
            let fixture = OAuthFixture()
            let client = fixture.client
            let flow = try await client.begin(endpoint: fixture.resource, redirect: redirect, clientID: "provided-client-id")
            let callback = try callbackURL(flow, [URLQueryItem(name: "code", value: "fixture-browser-code")])
            let invalid = try callbackURL(flow, [], state: URLQueryItem(name: "state", value: "wrong-state"))
            var request: Task<Void, any Error>?
            let received = try await listener.authorize(flow, seconds: 12) { url in
                XCTAssertEqual(url, flow.authorizationURL)
                request = Task {
                    let requester = URLSession(configuration: .ephemeral)
                    defer { requester.invalidateAndCancel() }
                    let (_, rejected) = try await requester.data(for: URLRequest(url: invalid, timeoutInterval: 5))
                    XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
                    let (data, response) = try await requester.data(for: URLRequest(url: callback, timeoutInterval: 5))
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                    XCTAssertFalse(try XCTUnwrap(String(bytes: data, encoding: .utf8)).contains("fixture-browser-code"))
                }
                return true
            }
            XCTAssertEqual(received, "fixture-browser-code")
            try await request?.value
        }
    #endif

    private func parts(of url: URL) throws -> URLComponents {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }

    private func callbackURL(
        _ flow: MCPOAuthClient.Flow, _ items: [URLQueryItem], state: URLQueryItem? = nil,
    ) throws -> URL {
        var callback = try parts(of: flow.redirect)
        callback.queryItems = items + [state ?? URLQueryItem(name: "state", value: flow.state)]
        return try XCTUnwrap(callback.url)
    }
}

private actor OAuthFixture {
    enum Mode {
        case normal, publishedClient, unpublishedClient, fallback, wrongResource, wrongIssuer, insecureToken, noPKCE
    }

    let resource = URL(string: "https://mcp.example.test/api/mcp")!
    let redirect = URL(string: "http://127.0.0.1:47863/oauth/callback")!
    let protectedMetadata = URL(string: "https://mcp.example.test/metadata")!
    let tokenEndpoint = URL(string: "https://auth.example.test/token")!
    private let issuer = "https://auth.example.test/tenant"
    private let mode: Mode
    private(set) var requests: [URLRequest] = []

    init(mode: Mode = .normal) {
        self.mode = mode
    }

    nonisolated var client: MCPOAuthClient {
        MCPOAuthClient { try await self.send($0, $1) }
    }

    private func send(_ request: URLRequest, _ readBody: Bool) throws -> MCPOAuthResponse {
        requests.append(request)
        switch request.url?.path {
        case resource.path:
            XCTAssertFalse(readBody)
            XCTAssertEqual(request.httpMethod, "POST")
            let challenge = mode == .fallback ? "Bearer" :
                #"Basic realm="legacy, admin", Bearer resource_metadata="https://mcp.example.test/metadata", scope  =  "tools:read files:read""#
            return MCPOAuthResponse(status: 401, challenge: challenge, body: Data())

        case protectedMetadata.path, "/.well-known/oauth-protected-resource":
            return try response([
                "resource": .string(mode == .wrongResource ? "https://mcp.example.test/other" : resource.absoluteString),
                "authorization_servers": .array([.string(issuer)]), "scopes_supported": .array([.string("tools:read")]),
            ])

        case "/.well-known/oauth-authorization-server/tenant" where mode != .fallback, "/tenant/.well-known/openid-configuration":
            return try response([
                "issuer": .string(mode == .wrongIssuer ? "https://another.example.test" : issuer),
                "authorization_endpoint": .string("https://auth.example.test/authorize"),
                "token_endpoint": .string(mode == .insecureToken ? "http://auth.example.test/token" : tokenEndpoint.absoluteString),
                "registration_endpoint": .string("https://auth.example.test/register"),
                "client_id_metadata_document_supported": .bool(mode == .publishedClient || mode == .unpublishedClient),
                "code_challenge_methods_supported": .array([.string(mode == .noPKCE ? "plain" : "S256")]),
            ])

        case "/mcp-oauth-client.json" where mode == .publishedClient:
            return try response([
                "client_id": .string("https://meetingtranscriber.app/mcp-oauth-client.json"), "client_name": .string("Meeting Transcriber"),
                "redirect_uris": .array([.string(redirect.absoluteString)]), "token_endpoint_auth_method": .string("none"),
            ])

        case "/register":
            return try response(["client_id": .string("fixture-public-client"), "token_endpoint_auth_method": .string("none")], status: 201)

        case "/token":
            let body = try XCTUnwrap(String(bytes: XCTUnwrap(request.httpBody), encoding: .utf8))
            let refresh = body.contains("grant_type=refresh_token")
            return try response([
                "token_type": .string("Bearer"), "access_token": .string(refresh ? "fixture-access-2" : "fixture-access-1"),
                "refresh_token": .string(refresh ? "fixture-refresh-2" : "fixture+refresh&1"), "expires_in": .integer(refresh ? 3600 : 5),
            ])

        default:
            return MCPOAuthResponse(status: 404, challenge: nil, body: Data())
        }
    }

    private func response(_ object: [String: ContextJSON], status: Int = 200) throws -> MCPOAuthResponse {
        try MCPOAuthResponse(status: status, challenge: nil, body: ContextJSON.encoded(object))
    }
}
