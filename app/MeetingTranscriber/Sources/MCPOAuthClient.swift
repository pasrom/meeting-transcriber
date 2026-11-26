import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum MCPOAuthError: String, Error, LocalizedError, Sendable {
    case discovery, pkce, registration, clientIDRequired, callback, denied, exchange, expired, storage

    var errorDescription: String? {
        switch self {
        case .discovery: "OAuth discovery failed. Check the server URL and its advertised authentication metadata."
        case .pkce: "The authorization server must advertise PKCE with S256."
        case .registration: "The authorization server could not register a public client."
        case .clientIDRequired: "This server requires a registered OAuth client ID or client metadata URL."
        case .callback: "The browser sign-in could not return to Meeting Transcriber. Check that the local callback port is available."
        case .denied: "Access was not granted by the authorization server."
        case .exchange: "The authorization server could not issue a usable bearer token."
        case .expired: "The saved MCP authorization has expired. Sign in again."
        case .storage: "The MCP authorization could not be saved in Keychain."
        }
    }
}

struct MCPOAuthCredentials: Codable, Sendable {
    let resource: URL
    let tokenEndpoint: URL
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    var values: [String] {
        [accessToken] + [refreshToken].compactMap(\.self)
    }

    func needsRefresh(at now: Date) -> Bool {
        expiresAt.map { $0 <= now.addingTimeInterval(30) } ?? false
    }

    func matches(_ endpoint: URL) -> Bool {
        guard let expected = MCPOAuthClient.resourceID(endpoint) else { return false }
        return MCPOAuthClient.resourceID(resource) == expected
            && MCPOAuthClient.httpsURL(tokenEndpoint.absoluteString) != nil
    }
}

struct MCPOAuthResponse: Sendable {
    let status: Int
    let challenge: String?
    let body: Data
}

struct MCPOAuthClient: Sendable {
    typealias Send = @Sendable (URLRequest, Bool) async throws -> MCPOAuthResponse
    static let loopbackPort: UInt16 = 47863
    private static let clientMetadataID = "https://meetingtranscriber.app/mcp-oauth-client.json"

    struct Metadata: Sendable {
        let resource: URL
        let issuer: URL
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
        let supportsClientMetadata: Bool
        let scopes: String?
    }

    struct Flow: Sendable {
        let metadata: Metadata
        let clientID: String
        let redirect: URL
        let state: String
        let verifier: String
        let authorizationURL: URL

        func code(from callback: URL) throws -> String {
            guard let fields = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  callback.scheme == redirect.scheme, callback.host == redirect.host, callback.port == redirect.port,
                  callback.path == redirect.path, callback.fragment == nil, callback.user == nil, callback.password == nil,
                  let items = fields.queryItems, let returnedState = Self.single("state", in: items),
                  returnedState == state else { throw MCPOAuthError.callback }
            if items.contains(where: { $0.name == "iss" }),
               Self.single("iss", in: items) != metadata.issuer.absoluteString { throw MCPOAuthError.callback }
            if items.contains(where: { $0.name == "error" }) { throw MCPOAuthError.denied }
            guard let code = Self.single("code", in: items), !code.isEmpty, code.utf8.count <= 4096 else {
                throw MCPOAuthError.callback
            }
            return code
        }

        private static func single(_ name: String, in items: [URLQueryItem]) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches.first?.value : nil
        }
    }

    private let send: Send

    init(send: @escaping Send = MCPOAuthHTTP.send) {
        self.send = send
    }

    func discover(endpoint: URL) async throws -> Metadata {
        guard Self.resourceID(endpoint) != nil else { throw MCPOAuthError.discovery }
        var probe = URLRequest(url: endpoint)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = try MCPWireMessage("initialize", id: 1, params: [
            "protocolVersion": .string("2025-11-25"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Meeting Transcriber"), "version": .string("1")]),
        ]).data
        let response = try await send(probe, false)
        let challenge = (response.status == 401 || response.status == 403) ? try MCPOAuthChallenge(response.challenge) : nil
        let resourceMetadata = try await protectedResource(endpoint, advertised: challenge?.metadata)
        let servers = resourceMetadata["authorization_servers"]?.array?.compactMap(\.string) ?? []
        guard let issuer = servers.prefix(8).compactMap({ Self.httpsURL($0, allowQuery: false) }).first else {
            throw MCPOAuthError.discovery
        }
        let document = try await authorizationServer(issuer)
        guard document["code_challenge_methods_supported"]?.array?.contains(.string("S256")) == true else {
            throw MCPOAuthError.pkce
        }
        guard let authorization = document["authorization_endpoint"]?.string.flatMap({ Self.httpsURL($0) }),
              let token = document["token_endpoint"]?.string.flatMap({ Self.httpsURL($0) }) else {
            throw MCPOAuthError.discovery
        }
        // A resource's supported scopes are capabilities, not a request for all of them.
        let scopes = challenge?.scope
        guard (scopes?.utf8.count ?? 0) <= 2048 else { throw MCPOAuthError.discovery }
        return Metadata(
            resource: endpoint, issuer: issuer, authorizationEndpoint: authorization, tokenEndpoint: token,
            registrationEndpoint: document["registration_endpoint"]?.string.flatMap { Self.httpsURL($0) },
            supportsClientMetadata: document["client_id_metadata_document_supported"] == .bool(true),
            scopes: scopes?.isEmpty == false ? scopes : nil,
        )
    }

    func begin(endpoint: URL, redirect: URL, clientID: String?) async throws -> Flow {
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil,
              redirect.path == "/oauth/callback", redirect.query == nil, redirect.fragment == nil,
              redirect.user == nil, redirect.password == nil else { throw MCPOAuthError.callback }
        let metadata = try await discover(endpoint: endpoint)
        let client: String = if let clientID, !clientID.isEmpty {
            clientID
        } else if metadata.supportsClientMetadata, await publishedClientSupports(redirect: redirect) {
            Self.clientMetadataID
        } else {
            try await register(metadata, redirect: redirect)
        }
        guard Self.validClientID(client) else { throw MCPOAuthError.registration }
        let state = Self.randomString()
        let verifier = Self.randomString()
        let challenge = Self.base64URL(ContextDigest.sha256(Data(verifier.utf8)))
        var fields = [
            "client_id": client, "code_challenge": challenge, "code_challenge_method": "S256",
            "redirect_uri": redirect.absoluteString, "response_type": "code",
            "resource": metadata.resource.absoluteString, "state": state,
        ]
        if let scope = metadata.scopes { fields["scope"] = scope }
        guard var url = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false),
              (url.queryItems ?? []).allSatisfy({ fields[$0.name] == nil }) else { throw MCPOAuthError.discovery }
        let query = Self.form(fields)
        url.percentEncodedQuery = [url.percentEncodedQuery, query].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "&")
        guard let authorizationURL = url.url else { throw MCPOAuthError.discovery }
        return Flow(metadata: metadata, clientID: client, redirect: redirect, state: state, verifier: verifier, authorizationURL: authorizationURL)
    }

    func finish(_ flow: Flow, code: String) async throws -> MCPOAuthCredentials {
        try await token(
            at: flow.metadata.tokenEndpoint, resource: flow.metadata.resource, clientID: flow.clientID,
            fields: [
                "code": code, "redirect_uri": flow.redirect.absoluteString,
                "code_verifier": flow.verifier, "grant_type": "authorization_code",
            ],
        )
    }

    func refresh(_ current: MCPOAuthCredentials, timeout: TimeInterval = TimeInterval(ContextLimits.operationSeconds)) async throws -> MCPOAuthCredentials {
        guard let refreshToken = current.refreshToken else { throw MCPOAuthError.expired }
        return try await token(
            at: current.tokenEndpoint, resource: current.resource, clientID: current.clientID,
            fields: ["grant_type": "refresh_token", "refresh_token": refreshToken], timeout: timeout,
        )
    }

    private func protectedResource(_ endpoint: URL, advertised: String?) async throws -> ContextJSON {
        let candidates: [URL]
        if let advertised {
            guard let url = Self.httpsURL(advertised) else { throw MCPOAuthError.discovery }
            candidates = [url]
        } else {
            candidates = Self.metadataURLs(endpoint, name: "oauth-protected-resource", includeRoot: true, append: false)
        }
        for url in candidates {
            guard let document = try await metadata(at: url) else { continue }
            guard let resource = document["resource"]?.string.flatMap({ Self.httpsURL($0, allowQuery: false) }),
                  Self.resourceID(resource) == Self.resourceID(endpoint) else { throw MCPOAuthError.discovery }
            return document
        }
        throw MCPOAuthError.discovery
    }

    private func authorizationServer(_ issuer: URL) async throws -> ContextJSON {
        let candidates = Self.metadataURLs(issuer, name: "oauth-authorization-server", includeRoot: false, append: false)
            + Self.metadataURLs(issuer, name: "openid-configuration", includeRoot: false, append: true)
        for url in candidates {
            guard let document = try await metadata(at: url) else { continue }
            guard document["issuer"]?.string == issuer.absoluteString else { throw MCPOAuthError.discovery }
            return document
        }
        throw MCPOAuthError.discovery
    }

    private func metadata(at url: URL) async throws -> ContextJSON? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = try await send(request, true)
        guard result.status == 200 else { return nil }
        return try JSONDecoder().decode(ContextJSON.self, from: result.body)
    }

    private func publishedClientSupports(redirect: URL) async -> Bool {
        guard let url = URL(string: Self.clientMetadataID), let document = try? await metadata(at: url) else { return false }
        return document["client_id"] == .string(Self.clientMetadataID)
            && document["redirect_uris"]?.array?.contains(.string(redirect.absoluteString)) == true
            && document["token_endpoint_auth_method"] == .string("none")
    }

    private func register(_ metadata: Metadata, redirect: URL) async throws -> String {
        guard let endpoint = metadata.registrationEndpoint else { throw MCPOAuthError.clientIDRequired }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ContextJSON.encoded([
            "client_name": ContextJSON.string("Meeting Transcriber"),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "redirect_uris": .array([.string(redirect.absoluteString)]),
            "token_endpoint_auth_method": .string("none"),
        ])
        let result = try await send(request, true)
        guard (200 ... 299).contains(result.status),
              let object = try? JSONDecoder().decode(ContextJSON.self, from: result.body),
              let id = object["client_id"]?.string,
              object["token_endpoint_auth_method"] == nil || object["token_endpoint_auth_method"] == .string("none") else {
            throw MCPOAuthError.registration
        }
        if let redirects = object["redirect_uris"]?.array, !redirects.contains(.string(redirect.absoluteString)) {
            throw MCPOAuthError.registration
        }
        return id
    }

    private func token(
        at endpoint: URL, resource: URL, clientID: String, fields: [String: String],
        timeout: TimeInterval = TimeInterval(ContextLimits.operationSeconds),
    ) async throws -> MCPOAuthCredentials {
        guard Self.httpsURL(endpoint.absoluteString) != nil else { throw MCPOAuthError.exchange }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parameters = fields
        parameters["client_id"] = clientID
        parameters["resource"] = resource.absoluteString
        request.httpBody = Data(Self.form(parameters).utf8)
        let result = try await send(request, true)
        guard (200 ... 299).contains(result.status),
              let object = try? JSONDecoder().decode(ContextJSON.self, from: result.body),
              object["token_type"]?.string?.lowercased() == "bearer",
              let access = object["access_token"]?.string, Self.validBearer(access) else { throw MCPOAuthError.exchange }
        let refresh = object["refresh_token"]?.string ?? fields["refresh_token"]
        guard refresh.map({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 }) ?? true else { throw MCPOAuthError.exchange }
        var expiresAt: Date?
        if let lifetime = object["expires_in"] {
            guard case let .integer(seconds) = lifetime, (1 ... 31_536_000).contains(seconds) else { throw MCPOAuthError.exchange }
            expiresAt = Date().addingTimeInterval(Double(seconds))
        }
        return MCPOAuthCredentials(
            resource: resource, tokenEndpoint: endpoint, clientID: clientID,
            accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
        )
    }

    static func httpsURL(_ value: String, allowQuery: Bool = true) -> URL? {
        guard value.utf8.count <= 2048, let url = URL(string: value),
              MCPSource.validEndpoint(url, allowLoopbackHTTP: false), allowQuery || url.query == nil else { return nil }
        return url
    }

    static func resourceID(_ url: URL) -> String? {
        guard httpsURL(url.absoluteString, allowQuery: false) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        if components.port == 443 { components.port = nil }
        if components.percentEncodedPath == "/" { components.percentEncodedPath = "" }
        return components.string
    }

    static func validBearer(_ value: String) -> Bool {
        value.utf8.count <= 4096 && value.range(of: #"\A[A-Za-z0-9._~+/-]+=*\z"#, options: .regularExpression) != nil
    }

    static func validClientID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 1024 && id.utf8.allSatisfy { (33 ... 126).contains($0) }
    }

    private static func metadataURLs(_ url: URL, name: String, includeRoot: Bool, append: Bool) -> [URL] {
        guard var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        let path = origin.percentEncodedPath == "/" ? "" : origin.percentEncodedPath
        let wellKnown = "/.well-known/" + name
        origin.percentEncodedPath = wellKnown + path
        let first = origin.url
        origin.percentEncodedPath = append ? String(path.dropLast(path.hasSuffix("/") ? 1 : 0)) + wellKnown : wellKnown
        let fallback = !path.isEmpty && (includeRoot || append) ? origin.url : nil
        return [first, fallback].compactMap(\.self)
    }

    private static let formCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func form(_ parameters: [String: String]) -> String {
        let ordered = parameters.sorted { $0.key < $1.key }
        return ordered.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? "")"
        }.joined(separator: "&")
    }

    private static func randomString() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
