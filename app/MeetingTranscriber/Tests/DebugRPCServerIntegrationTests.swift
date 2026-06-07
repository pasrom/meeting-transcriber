#if !APPSTORE
    @testable import MeetingTranscriber
    import Network
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

        private func startServer(
            snapshot: RPCStateSnapshot = .empty,
            enqueueFile: @escaping (URL) -> Bool = { _ in false },
            enqueueFiles: @escaping ([URL]) -> Int = { _ in 0 },
        ) async throws -> URL {
            let server = DebugRPCServer(
                port: 0,
                token: Self.testToken,
                snapshot: { snapshot },
                enqueueFile: enqueueFile,
                enqueueFiles: enqueueFiles,
            )
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
                speakerDB: .init(count: 7, recentNames: ["Alice"], knownSpeakerNames: ["Alice"]),
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

        func testMetricsReturnsLiveResourceSnapshot() async throws {
            let base = try await startServer()
            let (data, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("metrics"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                "application/json",
            )
            let decoded = try JSONDecoder().decode(RPCResourceMetrics.self, from: data)
            XCTAssertEqual(decoded.pid, getpid())
            XCTAssertGreaterThan(decoded.cpuUserSeconds + decoded.cpuSystemSeconds, 0)
            XCTAssertGreaterThan(decoded.physFootprintBytes, 0)
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

        // MARK: - /action/enqueueFile

        func testEnqueueFileMissingPathReturns400() async throws {
            let base = try await startServer()
            var req = request("POST", base.appendingPathComponent("action/enqueueFile"), headers: authHeader)
            req.httpBody = Data("{}".utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        func testEnqueueFileNonexistentPathReturns400() async throws {
            // Closure returns false → RPC layer translates to 400.
            let base = try await startServer { _ in false }
            var req = request("POST", base.appendingPathComponent("action/enqueueFile"), headers: authHeader)
            req.httpBody = Data(#"{"path":"/tmp/definitely-does-not-exist-\#(UUID().uuidString).wav"}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        func testEnqueueFileValidPathReturns200AndInvokesClosure() async throws {
            // Temp file the closure can `fileExists`-check if it chooses to.
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpc-enqueue-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: tmp.path, contents: Data("RIFF".utf8))
            defer { try? FileManager.default.removeItem(at: tmp) }

            // Use an actor-isolated box so we can observe from the test body
            // without sharing mutable state across the closure boundary.
            actor InvocationBox {
                var receivedPath: String?
                func record(_ p: String) {
                    receivedPath = p
                }
            }
            let box = InvocationBox()
            let base = try await startServer { url in
                Task { await box.record(url.path) }
                return true
            }

            var req = request("POST", base.appendingPathComponent("action/enqueueFile"), headers: authHeader)
            req.httpBody = Data(#"{"path":"\#(tmp.path)"}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

            // Closure dispatches into a Task — poll instead of a fixed sleep
            // so a slow lane (sanitizers ~7.5 min) doesn't flake on a tight
            // 50 ms budget. Worst-case wall is still 500 ms.
            var received: String?
            for _ in 0 ..< 20 {
                received = await box.receivedPath
                if received != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(received, tmp.path)
        }

        // MARK: - /action/enqueueFiles (paired import)

        func testEnqueueFilesMissingPathsReturns400() async throws {
            let base = try await startServer()
            var req = request("POST", base.appendingPathComponent("action/enqueueFiles"), headers: authHeader)
            req.httpBody = Data("{}".utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        func testEnqueueFilesEmptyArrayReturns400() async throws {
            let base = try await startServer()
            var req = request("POST", base.appendingPathComponent("action/enqueueFiles"), headers: authHeader)
            req.httpBody = Data(#"{"paths":[]}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        func testEnqueueFilesValidPathsReturns200WithCount() async throws {
            let tmpA = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpc-files-a-\(UUID().uuidString).wav")
            let tmpB = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpc-files-b-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: tmpA.path, contents: Data("RIFF".utf8))
            FileManager.default.createFile(atPath: tmpB.path, contents: Data("RIFF".utf8))
            defer {
                try? FileManager.default.removeItem(at: tmpA)
                try? FileManager.default.removeItem(at: tmpB)
            }

            actor CountBox {
                var receivedCount: Int = 0
                func record(_ n: Int) {
                    receivedCount = n
                }
            }
            let box = CountBox()
            // Explicit param to disambiguate from `enqueueFile: (URL) -> Bool`
            // (trailing-closure would bind to the wrong overload).
            let multi: ([URL]) -> Int = { urls in
                Task { await box.record(urls.count) }
                return urls.count
            }
            let base = try await startServer(enqueueFiles: multi)

            var req = request("POST", base.appendingPathComponent("action/enqueueFiles"), headers: authHeader)
            req.httpBody = Data(#"{"paths":["\#(tmpA.path)","\#(tmpB.path)"]}"#.utf8)
            let (data, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

            let body = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertEqual(body, #"{"enqueued":2}"#)

            var received = 0
            for _ in 0 ..< 20 {
                received = await box.receivedCount
                if received > 0 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(received, 2)
        }

        // MARK: - Listener lifecycle: don't-break-the-survivor + no leak on drop

        /// Construct + start a server pinned to a specific port and wait until it
        /// reports `boundPort`. Caller owns the returned strong ref (so the leak
        /// test can drop it deliberately). Does NOT store into `self.server`.
        private func startServerPinned(port: UInt16) async throws -> DebugRPCServer {
            let server = DebugRPCServer(port: port, token: Self.testToken) { .empty }
            server.start()
            for _ in 0 ..< 50 {
                if server.boundPort != nil { return server }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw XCTestError(.timeoutWhileWaiting)
        }

        private func healthzStatus(port: UInt16) async -> Int? {
            guard let url = URL(string: "http://127.0.0.1:\(port)/healthz") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 2
            req.setValue("Bearer \(Self.testToken)", forHTTPHeaderField: "Authorization")
            guard let (_, response) = try? await URLSession.shared.data(for: req) else { return nil }
            return (response as? HTTPURLResponse)?.statusCode
        }

        /// A second server whose bind collides with a live server must NOT damage
        /// the survivor: server A keeps serving after server B's bind fails. Pins
        /// the controller's reference-overwrite hazard at the socket layer — a
        /// doomed instance #2 may never disturb the live instance #1.
        func testCollidingSecondServerDoesNotBreakSurvivor() async throws {
            let serverA = try await startServerPinned(port: 0)
            let portA = try XCTUnwrap(serverA.boundPort)
            let before = await healthzStatus(port: portA)
            XCTAssertEqual(before, 200, "server A should serve before the collision")

            // B pinned to A's port → its bind fails (Address already in use). The
            // failure path must confine itself to B's own listener.
            let serverB = DebugRPCServer(port: portA, token: Self.testToken) { .empty }
            serverB.start()

            // Re-assert the survivor invariant repeatedly instead of sleeping a
            // fixed interval (CI-flaky on a loaded runner). B can never reach
            // `.ready` while A holds the port, so `boundPort` stays nil throughout;
            // A must answer 200 on every probe, so a transient mid-failure
            // regression surfaces, not just the end state. ~10 probes (each a real
            // healthz roundtrip + 50 ms step) span well past B's async bind-fail.
            for _ in 0 ..< 10 {
                let aStatus = await healthzStatus(port: portA)
                XCTAssertEqual(aStatus, 200, "server A must keep serving while B's bind fails")
                XCTAssertNil(serverB.boundPort, "B's colliding bind must never reach .ready")
                try await Task.sleep(for: .milliseconds(50))
            }

            serverA.stop()
            serverB.stop()
        }

        /// The wedge: a started server dropped WITHOUT `stop()` (the controller
        /// overwriting `self.server` with a fresh instance dealloc'd #1) must not
        /// leave its listener squatting the port. With the old `listener →
        /// stateUpdateHandler → listener` self-cycle the listener outlived the
        /// dealloc'd server, kept the LISTEN socket, and accepted connections that
        /// `self?` (now nil) never serviced. We assert the inverse: after dropping
        /// the only strong ref, a FRESH server can bind the same port and serve.
        func testDroppingServerWithoutStopReleasesPort() async throws {
            var first: DebugRPCServer? = try await startServerPinned(port: 0)
            let port = try XCTUnwrap(first?.boundPort)
            let firstStatus = await healthzStatus(port: port)
            XCTAssertEqual(firstStatus, 200, "first server should serve")

            // Drop the only strong reference WITHOUT stop() — models the controller
            // overwriting `self.server`. ARC must reclaim the listener (no cycle).
            first = nil

            // Poll the observable end-condition — a FRESH server can bind + serve
            // the same port — instead of a fixed sleep waiting for dealloc+cancel
            // to settle (CI-flaky on a loaded runner). Each attempt waits for the
            // candidate to reach `.ready` (or times out) before retrying; if the
            // old listener leaked and squatted the socket, every attempt fails and
            // the loop exhausts its ~5 s budget. The successful candidate is kept
            // and stopped once; failed candidates are released between attempts.
            var served = false
            for _ in 0 ..< 25 {
                if let candidate = try? await startServerPinned(port: port) {
                    let status = await healthzStatus(port: port)
                    candidate.stop()
                    if status == 200 {
                        served = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(
                served,
                "a fresh server must bind + serve the port the dropped one held",
            )
        }

        // MARK: - M6: Host header allowlist (raw-socket)

        /// `URLRequest.setValue(_:forHTTPHeaderField: "Host")` is silently
        /// ignored by URLSession — Host is reserved. To exercise the
        /// server's Host check we have to write the request bytes ourselves
        /// over a TCP socket.
        ///
        /// This test sends a syntactically valid HTTP/1.1 request with
        /// `Host: evil.example` and a valid bearer; expects a 403 from the
        /// route guard (not a 401 — auth would pass, Host comes first).
        func testRawSocketForeignHostReturns403() async throws {
            let base = try await startServer()
            guard let port = base.port else { XCTFail("no port"); return }

            let raw =
                "GET /healthz HTTP/1.1\r\n" +
                "Host: evil.example\r\n" +
                "Authorization: Bearer \(Self.testToken)\r\n" +
                "\r\n"

            let response = try await sendRawHTTP(toPort: UInt16(port), bytes: Data(raw.utf8))
            let firstLine = response.split(separator: "\n").first ?? ""
            XCTAssertTrue(
                firstLine.contains("403"),
                "Expected 403 for foreign Host, got: \(firstLine)",
            )
        }

        /// Same shape, but the Host is loopback — must pass the allowlist
        /// and reach 200. Confirms we didn't accidentally close the door
        /// on legitimate clients.
        func testRawSocketLoopbackHostReturns200() async throws {
            let base = try await startServer()
            guard let port = base.port else { XCTFail("no port"); return }

            let raw =
                "GET /healthz HTTP/1.1\r\n" +
                "Host: 127.0.0.1:\(port)\r\n" +
                "Authorization: Bearer \(Self.testToken)\r\n" +
                "\r\n"

            let response = try await sendRawHTTP(toPort: UInt16(port), bytes: Data(raw.utf8))
            let firstLine = response.split(separator: "\n").first ?? ""
            XCTAssertTrue(
                firstLine.contains("200"),
                "Expected 200 for loopback Host, got: \(firstLine)",
            )
        }

        /// Open a TCP connection to `port`, write `bytes`, read response,
        /// return as String. Used by the raw-socket Host tests because
        /// URLSession reserves the `Host` header.
        private func sendRawHTTP(toPort port: UInt16, bytes: Data) async throws -> String {
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port) ?? .any,
                using: .tcp,
            )
            return try await withCheckedThrowingContinuation { continuation in
                let resumer = OneShotResumer(continuation, connection: connection)
                connection.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        resumer.fail(error)
                    }
                }
                connection.start(queue: .global())
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error {
                        resumer.fail(error)
                        return
                    }
                    receiveUntilHeadersComplete(connection: connection, resumer: resumer)
                })
            }
        }
    }

    /// Read repeatedly until the server's status line + headers are in,
    /// then resume with the accumulated bytes as a UTF-8 string. The
    /// debug RPC keeps the connection open after responding, so we use
    /// `\r\n\r\n` as the "headers ended" marker rather than waiting for
    /// `isComplete`. File-scope (non-isolated) so it can be called from
    /// the Network.framework callbacks that run off the main actor.
    private func receiveUntilHeadersComplete(
        connection: NWConnection, resumer: OneShotResumer, accumulated: Data = Data(),
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, _ in
            var buffer = accumulated
            if let data { buffer.append(data) }
            let body = String(data: buffer, encoding: .utf8) ?? ""
            if isComplete || body.contains("\r\n\r\n") {
                resumer.succeed(body)
                return
            }
            receiveUntilHeadersComplete(connection: connection, resumer: resumer, accumulated: buffer)
        }
    }

    /// Resumes a `CheckedContinuation` exactly once and cancels the underlying
    /// connection. Multiple callbacks (state-failed, send-error, receive-error
    /// or receive-success) can race; without this the second resume would
    /// trip the runtime check.
    private final class OneShotResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<String, any Error>
        private let connection: NWConnection

        init(_ continuation: CheckedContinuation<String, any Error>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func succeed(_ body: String) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(returning: body)
            connection.cancel()
        }

        func fail(_ error: any Error) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(throwing: error)
            connection.cancel()
        }
    }
#endif
