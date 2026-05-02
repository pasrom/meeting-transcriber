#if !APPSTORE
    import AppKit
    import Foundation
    import Network
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DebugRPCServer")

    /// Local-only HTTP server that exposes app state for shell-driven inspection.
    /// Gated by `MEETINGTRANSCRIBER_DEBUG_RPC=1` env var; never started in
    /// production builds (the `#if !APPSTORE` wraps the whole file).
    ///
    /// Bind: `127.0.0.1:9876`. Two layers of defense:
    /// - Origin-header reject blocks browser CSRF / DNS-rebinding (`fetch()` from a
    ///   page on the user's machine sends Origin; curl and native CLIs don't).
    /// - Bearer-token auth read from `~/Library/Application Support/MeetingTranscriber/.rpc-token`
    ///   (chmod 0600) keeps other local users on a shared Mac out and adds
    ///   defense-in-depth against compromised processes that lack read access
    ///   to the user's data dir.
    @MainActor
    final class DebugRPCServer {
        nonisolated static let envVar = "MEETINGTRANSCRIBER_DEBUG_RPC"
        nonisolated static let defaultPort: UInt16 = 9876
        nonisolated static let tokenFileURL = AppPaths.dataDir.appendingPathComponent(".rpc-token")

        private let port: NWEndpoint.Port
        private let snapshot: () -> RPCStateSnapshot
        private let expectedAuth: String
        private var listener: NWListener?

        /// True when the env flag is set. Use this from `AppState` to decide
        /// whether to construct + start a server at all.
        nonisolated static var enabled: Bool {
            ProcessInfo.processInfo.environment[envVar] == "1"
        }

        init(
            port: UInt16 = DebugRPCServer.defaultPort,
            token: String = DebugRPCServer.loadOrCreateToken(),
            snapshot: @escaping () -> RPCStateSnapshot,
        ) {
            self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port.any
            self.expectedAuth = "Bearer \(token)"
            self.snapshot = snapshot
        }

        /// Generate a 32-byte hex token, persist atomically with mode 0600, return it.
        /// Reuses an existing non-empty file so `mt-cli` survives across launches.
        nonisolated static func loadOrCreateToken() -> String {
            let url = tokenFileURL
            if let data = try? Data(contentsOf: url),
               let existing = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty {
                return existing
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            // SecRandomCopyBytes returning non-zero means the buffer is
            // unmodified (all zeros) — refuse to write that as a token.
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                logger.error("DebugRPCServer: SecRandomCopyBytes failed; using UUID fallback")
                return UUID().uuidString
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            // createFile with .posixPermissions sets mode at creation time —
            // avoids the brief 0644 window that a write-then-chmod sequence has.
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data(token.utf8),
                attributes: [.posixPermissions: 0o600],
            )
            return token
        }

        /// Start listening. Failures (port in use, etc.) are logged and the
        /// server stays down — the app still functions normally.
        func start() {
            guard listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.acceptLocalOnly = true
                let listener = try NWListener(using: params, on: port)
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.handle(connection) }
                }
                listener.start(queue: .main)
                self.listener = listener
                logger.info("DebugRPCServer listening on 127.0.0.1:\(self.port.rawValue, privacy: .public)")
            } catch {
                logger.error("DebugRPCServer failed to start: \(error.localizedDescription)")
            }
        }

        // MARK: - Connection handling

        private func handle(_ connection: NWConnection) {
            connection.start(queue: .main)
            receive(connection: connection, accumulated: Data())
        }

        private func receive(connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        logger.warning("RPC connection error: \(error.localizedDescription)")
                        connection.cancel()
                        return
                    }
                    var buffer = accumulated
                    if let data { buffer.append(data) }
                    // Wait for the full request line + headers (terminator \r\n\r\n)
                    if let request = HTTPRequest.parse(buffer) {
                        let response = self.route(request)
                        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    } else if isComplete {
                        connection.cancel()
                    } else {
                        self.receive(connection: connection, accumulated: buffer)
                    }
                }
            }
        }

        // MARK: - Routing

        func route(_ request: HTTPRequest) -> HTTPResponse {
            if let origin = request.headers["origin"], !origin.isEmpty, origin != "null" {
                return HTTPResponse.forbidden()
            }
            guard request.headers["authorization"] == expectedAuth else {
                return HTTPResponse.unauthorized()
            }

            switch (request.method, request.path) {
            case ("GET", "/state"):
                let json = try? snapshot().jsonData()
                return HTTPResponse.ok(body: json ?? Data(), contentType: "application/json")

            case ("GET", "/healthz"):
                return HTTPResponse.ok(body: Data("ok\n".utf8), contentType: "text/plain")

            case ("GET", "/screenshot"):
                if let png = Self.captureFrontmostWindowPNG() {
                    return HTTPResponse.ok(body: png, contentType: "image/png")
                }
                return HTTPResponse(
                    status: 503, reason: "Service Unavailable",
                    body: Data("no window\n".utf8), contentType: "text/plain",
                )

            default:
                return HTTPResponse.notFound()
            }
        }

        // MARK: - Screenshot

        /// PNG of the app's frontmost window, or nil if no window is visible.
        /// Uses the in-process NSWindow → bitmap path; no Screen Recording
        /// permission needed (the app captures itself).
        nonisolated static func captureFrontmostWindowPNG() -> Data? {
            // Hop to the main thread synchronously — NSApp/NSWindow are
            // main-thread-only and the receive() handler already lives there,
            // but `nonisolated static` means callers from tests or background
            // contexts can also reach this safely.
            MainActor.assumeIsolated {
                // NSApplication.shared lazily inits NSApp; access it first so
                // headless test runs don't crash on the implicit-unwrap NSApp.
                let app = NSApplication.shared
                guard let window = app.keyWindow ?? app.windows.first(where: \.isVisible) else {
                    return nil
                }
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { return nil }
                view.cacheDisplay(in: view.bounds, to: rep)
                return rep.representation(using: .png, properties: [:])
            }
        }
    }

    // MARK: - HTTP types

    struct HTTPRequest: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }

        static func parse(_ data: Data) -> Self? {
            // Need a complete header section before we can parse — the body
            // length is in Content-Length.
            let separator = Data("\r\n\r\n".utf8)
            guard let separatorRange = data.range(of: separator) else { return nil }
            let headerData = data.subdata(in: 0 ..< separatorRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            let method = String(parts[0])
            let path = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                guard pieces.count == 2 else { continue }
                let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = pieces[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            let bodyStart = separatorRange.upperBound
            let availableBody = data.count - bodyStart
            guard availableBody >= contentLength else { return nil }
            let body = data.subdata(in: bodyStart ..< bodyStart + contentLength)
            return Self(method: method, path: path, headers: headers, body: body)
        }
    }

    struct HTTPResponse {
        let status: Int
        let reason: String
        let body: Data
        let contentType: String

        static func ok(body: Data, contentType: String) -> Self {
            Self(status: 200, reason: "OK", body: body, contentType: contentType)
        }

        static func notFound() -> Self {
            Self(status: 404, reason: "Not Found", body: Data(), contentType: "text/plain")
        }

        static func unauthorized() -> Self {
            Self(status: 401, reason: "Unauthorized", body: Data(), contentType: "text/plain")
        }

        static func forbidden() -> Self {
            Self(status: 403, reason: "Forbidden", body: Data(), contentType: "text/plain")
        }

        func serialize() -> Data {
            var response = "HTTP/1.1 \(status) \(reason)\r\n"
            response += "Content-Type: \(contentType)\r\n"
            response += "Content-Length: \(body.count)\r\n"
            response += "Connection: close\r\n"
            response += "\r\n"
            var out = Data(response.utf8)
            out.append(body)
            return out
        }
    }

    // MARK: - State snapshot

    /// JSON-serialisable snapshot of the bits of app state useful for shell
    /// inspection. Kept deliberately minimal — extend as endpoints need it.
    struct RPCStateSnapshot: Codable {
        let pipeline: Pipeline
        let speakerDB: SpeakerDB
        let pendingNamingJobs: [PendingNaming]

        struct Pipeline: Codable {
            let isProcessing: Bool
            let activeJobCount: Int
            let waitingJobCount: Int
            let pendingNamingJobCount: Int
        }

        struct SpeakerDB: Codable {
            let count: Int
            /// Top-N most recently used names — useful to confirm a confirm hit DB.
            let recentNames: [String]
        }

        struct PendingNaming: Codable {
            let jobID: String
            let meetingTitle: String
            let speakerCount: Int
            let namingSlug: String?
        }

        func jsonData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }

        static let empty = Self(
            pipeline: .init(
                isProcessing: false, activeJobCount: 0,
                waitingJobCount: 0, pendingNamingJobCount: 0,
            ),
            speakerDB: .init(count: 0, recentNames: []),
            pendingNamingJobs: [],
        )
    }
#endif
