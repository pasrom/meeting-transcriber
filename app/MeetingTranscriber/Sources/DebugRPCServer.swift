// `@preconcurrency import ScreenCaptureKit`: SCShareableContent isn't
// Sendable on macos-26 SDK; call sites are @MainActor so it's safe.
#if !APPSTORE
    import AppKit
    import Foundation
    import Network
    import os.log
    @preconcurrency import ScreenCaptureKit

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

        /// Constant-time byte-wise equality. Used to compare incoming bearer
        /// tokens against the expected value so an attacker on a shared Mac
        /// can't infer a token by measuring early-mismatch latency. Iterates
        /// the longer of the two strings unconditionally; length differences
        /// still return false but only after walking both fully.
        nonisolated static func constantTimeEquals(_ provided: String, _ expected: String) -> Bool {
            let a = Array(provided.utf8)
            let b = Array(expected.utf8)
            let len = max(a.count, b.count)
            var diff: UInt8 = a.count == b.count ? 0 : 1
            for i in 0 ..< len {
                let av: UInt8 = i < a.count ? a[i] : 0
                let bv: UInt8 = i < b.count ? b[i] : 0
                diff |= (av ^ bv)
            }
            return diff == 0
        }

        /// Validate the request's `Host` header against `127.0.0.1` /
        /// `localhost` (with or without our bound port). Empty Host is
        /// accepted because old HTTP/1.0 clients and our own loopback
        /// probes don't always set one; the bind + bearer check still
        /// gates them. Defense-in-depth against DNS-rebinding payloads
        /// where an attacker's site resolves a hostname to 127.0.0.1
        /// and the browser dutifully sends `Host: evil.example`.
        nonisolated static func isHostAllowed(_ host: String, port: UInt16) -> Bool {
            if host.isEmpty { return true }
            let allowedNoPort: Set = ["127.0.0.1", "localhost"]
            if allowedNoPort.contains(host) { return true }
            let allowedWithPort: Set = [
                "127.0.0.1:\(port)",
                "localhost:\(port)",
            ]
            return allowedWithPort.contains(host)
        }

        /// Cap accumulated bytes per connection so a misbehaving client
        /// streaming bytes without `\r\n\r\n` can't OOM the app.
        private static let maxRequestBytes = 64 * 1024

        /// Skip status-item-style windows. The menu-bar `keyWindow` at idle is a
        /// 68×66 invisible rect — capturing it returns useless white pixels.
        private static let minWindowAreaPx: CGFloat = 10000

        private let port: NWEndpoint.Port
        private let snapshot: () -> RPCStateSnapshot
        private let speakerActions: SpeakerDBActions
        private let skipNaming: () -> Void
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
            skipNaming: @escaping () -> Void = {},
        ) {
            self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port.any
            self.expectedAuth = "Bearer \(token)"
            self.snapshot = snapshot
            self.speakerActions = speakerActions
            self.skipNaming = skipNaming
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
            return rotateToken(at: url)
        }

        /// Unconditionally write a fresh 32-byte hex token to `url`. Used by the
        /// settings toggle so that flipping the server off → on invalidates any
        /// previously-leaked token. Mode 0600 is set at create time to avoid
        /// the brief 0644 window a write-then-chmod sequence would have.
        @discardableResult
        nonisolated static func rotateToken(at url: URL = tokenFileURL) -> String {
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
            // Remove any prior file so createFile re-applies the 0600 attribute
            // even if the existing inode had drifted to a looser mode.
            try? FileManager.default.removeItem(at: url)
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
                        let response = await self.route(request)
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

        func route(_ request: HTTPRequest) async -> HTTPResponse {
            if let origin = request.headers["origin"], !origin.isEmpty, origin != "null" {
                return HTTPResponse.forbidden()
            }
            let hostPort = boundPort ?? port.rawValue
            guard Self.isHostAllowed(request.headers["host"] ?? "", port: hostPort) else {
                return HTTPResponse.forbidden()
            }
            let provided = request.headers["authorization"] ?? ""
            guard Self.constantTimeEquals(provided, expectedAuth) else {
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

            case ("POST", "/action/skipNaming"):
                // Skips ALL pending speaker-naming jobs in one shot — driver
                // scripts (e2e-app.sh) just want to drain the queue without
                // blocking on a UI dialog. Fire-and-forget; returns 200 even
                // if there's nothing pending.
                skipNaming()
                return HTTPResponse.ok(body: Data("ok\n".utf8), contentType: "text/plain")

            case ("POST", "/action/renameSpeaker"),
                 ("POST", "/action/deleteSpeaker"),
                 ("POST", "/action/mergeSpeakers"),
                 ("POST", "/action/seedSpeaker"):
                return routeSpeakerAction(path: request.path, body: request.body)

            case ("GET", "/screenshot"):
                if let png = await Self.captureFrontmostWindowPNG() {
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

        /// Decode the request body for one of the four speaker-DB action paths,
        /// run the matching closure on `speakerActions`, and return the mapped
        /// HTTP response. 400 on missing/empty fields or undecodable JSON.
        private func routeSpeakerAction(path: String, body: Data) -> HTTPResponse {
            switch path {
            case "/action/renameSpeaker":
                guard let p = try? JSONDecoder().decode(RenamePayload.self, from: body),
                      !p.from.isEmpty, !p.to.isEmpty
                else { return HTTPResponse.badRequest() }
                return Self.respond(to: speakerActions.rename(p.from, p.to))

            case "/action/deleteSpeaker":
                guard let p = try? JSONDecoder().decode(DeletePayload.self, from: body),
                      !p.name.isEmpty
                else { return HTTPResponse.badRequest() }
                return Self.respond(to: speakerActions.delete(p.name))

            case "/action/mergeSpeakers":
                guard let p = try? JSONDecoder().decode(MergePayload.self, from: body),
                      !p.from.isEmpty, !p.into.isEmpty
                else { return HTTPResponse.badRequest() }
                return Self.respond(to: speakerActions.merge(p.from, p.into))

            case "/action/seedSpeaker":
                guard let p = try? JSONDecoder().decode(SeedPayload.self, from: body),
                      !p.name.isEmpty
                else { return HTTPResponse.badRequest() }
                return Self.respond(to: speakerActions.seed(p.name))

            default:
                return HTTPResponse.notFound()
            }
        }

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

        private struct SeedPayload: Decodable {
            let name: String
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

        /// SwiftUI scene identifiers we expose to `/screenshot`. SpeakerNamingView
        /// (`speaker-naming`) is deliberately excluded because it surfaces real
        /// participant names and meeting titles — capturing it would let any
        /// local process with the RPC token read PII off-screen. Record-app
        /// picker (`record-app`) is excluded by default for the same reason
        /// (it lists the user's running apps); add to the set if a screenshot
        /// of it becomes useful for debugging. System file pickers, AppKit
        /// alerts, and similar transients carry no SwiftUI identifier and are
        /// rejected by the nil/empty case.
        nonisolated static let screenshotAllowedWindowIDs: Set<String> = ["settings"]

        nonisolated static func isWindowAllowedForScreenshot(identifier: String?) -> Bool {
            guard let identifier, !identifier.isEmpty else { return false }
            return screenshotAllowedWindowIDs.contains(identifier)
        }

        /// PNG of the largest visible content window from the screenshot
        /// allowlist, or nil when none qualifies. Uses ScreenCaptureKit
        /// (`SCScreenshotManager.captureImage`) — the non-deprecated successor
        /// to `CGWindowListCreateImage`. Unlike the old API, SCK requires
        /// Screen Recording permission even for self-capture; the first
        /// request triggers the standard TCC prompt. Acceptable for this
        /// debug-only path (whole file is `#if !APPSTORE`, RPC is opt-in).
        @MainActor
        static func captureFrontmostWindowPNG() async -> Data? {
            let app = NSApplication.shared
            let area: (NSWindow) -> CGFloat = { window in
                let b = window.contentView?.bounds ?? .zero
                return b.width * b.height
            }
            let candidate = app.windows
                .filter { window in
                    isWindowAllowedForScreenshot(identifier: window.identifier?.rawValue)
                        && window.isVisible
                        && window.contentView != nil
                }
                .max { area($0) < area($1) }
            guard let window = candidate, area(window) >= minWindowAreaPx else { return nil }
            let windowID = CGWindowID(window.windowNumber)
            do {
                let content = try await SCShareableContent.current
                guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                let scale = window.backingScaleFactor
                config.width = max(Int(scWindow.frame.width * scale), 1)
                config.height = max(Int(scWindow.frame.height * scale), 1)
                config.showsCursor = false
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config,
                )
                let rep = NSBitmapImageRep(cgImage: cgImage)
                return rep.representation(using: .png, properties: [:])
            } catch {
                logger.warning("Screenshot capture failed: \(error.localizedDescription, privacy: .public)")
                return nil
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
    /// `@MainActor`-isolated closures so the struct is `Sendable` (every
    /// invocation happens on MainActor anyway — RPC routing is itself
    /// MainActor-bound — so the isolation doesn't change call-site semantics).
    struct SpeakerDBActions {
        let rename: @MainActor (String, String) -> SpeakerActionOutcome
        let delete: @MainActor (String) -> SpeakerActionOutcome
        let merge: @MainActor (String, String) -> SpeakerActionOutcome
        /// Insert a synthetic speaker with a random embedding. Test-only path
        /// — production never calls this.
        let seed: @MainActor (String) -> SpeakerActionOutcome

        static let noop = Self(
            rename: { _, _ in .invalid },
            delete: { _ in .invalid },
            merge: { _, _ in .invalid },
            seed: { _ in .invalid },
        )
    }

#endif
