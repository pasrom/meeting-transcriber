import Foundation

/// Thin HTTP client for the running Meeting Transcriber app's debug RPC server.
/// Reads the bearer token from disk at the same path the app writes it to.
struct RPCClient {
    let baseURL: URL
    let token: String

    enum RPCError: Error, CustomStringConvertible {
        case appNotRunning(URL)
        case http(status: Int, body: String)
        case missingToken(URL)

        var description: String {
            switch self {
            case let .appNotRunning(url):
                "Meeting Transcriber app is not running on \(url.absoluteString) " +
                    "(or MEETINGTRANSCRIBER_DEBUG_RPC=1 was not set when it launched)"
            case let .http(status, body):
                "RPC returned HTTP \(status): \(body)"
            case let .missingToken(url):
                "RPC token not found at \(url.path) — start the app with " +
                    "MEETINGTRANSCRIBER_DEBUG_RPC=1 first"
            }
        }
    }

    /// Default app data dir on macOS. Mirrors `AppPaths.dataDir` in the app —
    /// duplicated here so mt-cli has no dependency on the app's source.
    static let defaultTokenURL: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("MeetingTranscriber")
            .appendingPathComponent(".rpc-token")
    }()

    static let defaultBaseURL = URL(string: "http://127.0.0.1:9876")!

    static func loadDefault() throws -> RPCClient {
        let url = defaultTokenURL
        guard let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw RPCError.missingToken(url)
        }
        return RPCClient(baseURL: defaultBaseURL, token: token)
    }

    func get(_ path: String) async throws -> Data {
        try await request("GET", path: path, body: nil)
    }

    func post(_ path: String, json: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await request("POST", path: path, body: body)
    }

    private func request(_ method: String, path: String, body: Data?) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return data }
            if (200 ..< 300).contains(http.statusCode) {
                return data
            }
            throw RPCError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "",
            )
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw RPCError.appNotRunning(baseURL)
        }
    }
}
