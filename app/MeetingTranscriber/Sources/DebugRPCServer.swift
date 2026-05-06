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

        /// Cap accumulated bytes per connection so a misbehaving client
        /// streaming bytes without `\r\n\r\n` can't OOM the app.
        private static let maxRequestBytes = 64 * 1024

        /// Skip status-item-style windows. The menu-bar `keyWindow` at idle is a
        /// 68×66 invisible rect — capturing it returns useless white pixels.
        private static let minWindowAreaPx: CGFloat = 10000

        private let port: NWEndpoint.Port
        private let snapshot: () -> RPCStateSnapshot
        private let speakerActions: SpeakerDBActions
        private let expectedAuth: String
        private var listener: NWListener?
        /// OS-assigned port once the listener is `.ready`. Useful for tests
        /// that bind to port 0 and need to know where to connect back.
        private(set) var boundPort: UInt16?

        nonisolated static var enabled: Bool {
            ProcessInfo.processInfo.environment[envVar] == "1"
        }

        init(
            port: UInt16 = DebugRPCServer.defaultPort,
            token: String = DebugRPCServer.loadOrCreateToken(),
            snapshot: @escaping () -> RPCStateSnapshot,
            speakerActions: SpeakerDBActions = .noop,
        ) {
            self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port.any
            self.expectedAuth = "Bearer \(token)"
            self.snapshot = snapshot
            self.speakerActions = speakerActions
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
                listener.stateUpdateHandler = { [weak self] state in
                    guard case .ready = state, let self else { return }
                    Task { @MainActor in self.boundPort = listener.port?.rawValue }
                }
                listener.start(queue: .main)
                self.listener = listener
                logger.info("DebugRPCServer listening on 127.0.0.1:\(self.port.rawValue, privacy: .public)")
            } catch {
                logger.error("DebugRPCServer failed to start: \(error.localizedDescription)")
            }
        }

        /// Cancel the listener and free the port. Idempotent.
        func stop() {
            listener?.cancel()
            listener = nil
            boundPort = nil
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
                    if buffer.count > Self.maxRequestBytes {
                        connection.cancel()
                        return
                    }
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

            case ("POST", "/action/openSettings"):
                Self.openSettings()
                return HTTPResponse.ok(body: Data("ok\n".utf8), contentType: "text/plain")

            case ("POST", "/action/closeSettings"):
                Self.closeSettings()
                return HTTPResponse.ok(body: Data("ok\n".utf8), contentType: "text/plain")

            case ("POST", "/action/renameSpeaker"):
                guard let payload = try? JSONDecoder().decode(RenamePayload.self, from: request.body),
                      !payload.from.isEmpty, !payload.to.isEmpty
                else { return HTTPResponse.badRequest() }
                return Self.respond(to: speakerActions.rename(payload.from, payload.to))

            case ("POST", "/action/deleteSpeaker"):
                guard let payload = try? JSONDecoder().decode(DeletePayload.self, from: request.body),
                      !payload.name.isEmpty
                else { return HTTPResponse.badRequest() }
                return Self.respond(to: speakerActions.delete(payload.name))

            case ("POST", "/action/mergeSpeakers"):
                guard let payload = try? JSONDecoder().decode(MergePayload.self, from: request.body),
                      !payload.from.isEmpty, !payload.into.isEmpty
                else { return HTTPResponse.badRequest() }
                return Self.respond(to: speakerActions.merge(payload.from, payload.into))

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

        // MARK: - Speaker DB action helpers

        private struct RenamePayload: Decodable {
            let from: String
            let to: String
        }

        private struct DeletePayload: Decodable {
            let name: String
        }

        private struct MergePayload: Decodable {
            let from: String
            let into: String
        }

        /// Map the action outcome to an HTTP response. `notFound` → 404,
        /// `invalid` → 400, everything else → 200 with the outcome string in the body.
        private static func respond(to outcome: SpeakerActionOutcome) -> HTTPResponse {
            switch outcome {
            case .notFound:
                return HTTPResponse.notFound()

            case .invalid:
                return HTTPResponse.badRequest()

            case .ok, .noop, .merged:
                let body = Data(#"{"outcome":"\#(outcome.rawValue)"}"#.utf8)
                return HTTPResponse.ok(body: body, contentType: "application/json")
            }
        }

        // MARK: - Actions

        /// Open the Settings window. Mirrors the menu-bar path:
        /// the @main scene listens for `.showSettings` and calls `bringWindowToFront`.
        @MainActor
        static func openSettings() {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .showSettings, object: nil)
        }

        /// Fire-and-forget close. SwiftUI no-ops when the window isn't open.
        @MainActor
        static func closeSettings() {
            NotificationCenter.default.post(name: .closeSettings, object: nil)
        }

        // MARK: - Screenshot

        /// PNG of the largest visible content window, or nil when none qualifies.
        /// The app captures itself, so no Screen Recording permission is needed.
        @MainActor
        static func captureFrontmostWindowPNG() -> Data? {
            let app = NSApplication.shared
            let area: (NSWindow) -> CGFloat = { window in
                let b = window.contentView?.bounds ?? .zero
                return b.width * b.height
            }
            let candidate = app.windows
                .filter { $0.isVisible && $0.contentView != nil }
                .max { area($0) < area($1) }
            guard let window = candidate, area(window) >= minWindowAreaPx else { return nil }
            // CGWindowListCreateImage composites real SwiftUI/Metal content;
            // NSView.cacheDisplay produces blank PNGs for layer-backed views.
            let windowID = CGWindowID(window.windowNumber)
            guard let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.bestResolution, .boundsIgnoreFraming],
            ) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            return rep.representation(using: .png, properties: [:])
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

        static func badRequest() -> Self {
            Self(status: 400, reason: "Bad Request", body: Data(), contentType: "text/plain")
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

    // MARK: - Speaker DB action types

    enum SpeakerActionOutcome: String {
        case ok
        case noop
        case merged
        case notFound
        case invalid
    }

    /// Default `.noop` rejects every request so tests and dry-launches can't
    /// accidentally mutate state — wire real closures explicitly when starting.
    struct SpeakerDBActions {
        var rename: (String, String) -> SpeakerActionOutcome
        var delete: (String) -> SpeakerActionOutcome
        var merge: (String, String) -> SpeakerActionOutcome

        static let noop = Self(
            rename: { _, _ in .invalid },
            delete: { _ in .invalid },
            merge: { _, _ in .invalid },
        )
    }

    // MARK: - State snapshot

    /// JSON-serialisable snapshot of state useful for shell inspection.
    /// Deliberately minimal — extend as endpoints need it.
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
