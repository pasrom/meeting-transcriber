// swiftlint:disable file_length
#if !APPSTORE
    @testable import MeetingTranscriber
    import Network
    import XCTest

    /// Real socket roundtrips: build a server, hit it via URLSession on the
    /// OS-assigned port, assert the response. Catches what the unit tests
    /// can't — actual NWListener wiring, header bytes on the wire, the
    /// receive() loop's framing logic.
    @MainActor
    // swiftlint:disable:next attributes type_body_length
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
            enqueueReturningIDs: @escaping ([URL]) -> [UUID] = { _ in [] },
            jobStatus: @escaping (UUID) -> JobStatusDTO? = { _ in nil },
            namingStatus: @escaping (UUID) -> NamingStatusDTO? = { _ in nil },
            confirmNaming: @escaping (UUID, [String: String]) -> Bool = { _, _ in false },
            skipJobNaming: @escaping (UUID) -> Bool = { _ in false },
            transcribe: @escaping (URL, Double) async -> BlockingTranscribeResult = { _, _ in .noFile },
        ) async throws -> URL {
            let server = DebugRPCServer(
                port: 0,
                token: Self.testToken,
                snapshot: { snapshot },
                enqueueFile: enqueueFile,
                enqueueFiles: enqueueFiles,
                enqueueReturningIDs: enqueueReturningIDs,
                jobStatus: jobStatus,
                namingStatus: namingStatus,
                confirmNaming: confirmNaming,
                skipJobNaming: skipJobNaming,
                transcribe: transcribe,
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

        /// End-to-end wire check for the notification ring buffer: post through
        /// the production notifier chokepoint, project it through the REAL
        /// `AppState.rpcStateSnapshot()` (injected notifier, no re-implemented
        /// mapping), and assert the `{title, body, postedAt, delivered}` rows
        /// come back over a real socket in chronological order. A fresh
        /// `NotificationManager` (not `.shared`) keeps the buffer isolated.
        func testStateExposesPostedNotifications() async throws {
            let manager = NotificationManager()
            let suite = "DebugRPCServerIntegrationTests-\(getpid())-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let state = AppState(settings: AppSettings(defaults: defaults), notifier: manager)
            defer { state.liveCaptions.clear() }
            manager.notify(title: "Meeting Detected", body: "Recording: Standup (Teams)")
            manager.notify(title: "Silent Recording", body: "Both channels silent")

            let base = try await startServer(snapshot: state.rpcStateSnapshot())
            let (data, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("state"), headers: authHeader),
            )

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(RPCStateSnapshot.self, from: data)
            XCTAssertEqual(decoded.notifications.map(\.title), ["Meeting Detected", "Silent Recording"])
            XCTAssertEqual(decoded.notifications.map(\.body), ["Recording: Standup (Teams)", "Both channels silent"])
            // Test host has no app bundle, so the delivery guard fails: the wire
            // must report the entries as NOT delivered.
            XCTAssertEqual(decoded.notifications.map(\.delivered), [false, false])
            let first = try XCTUnwrap(decoded.notifications.first)
            XCTAssertNotNil(
                ISO8601DateFormatter().date(from: first.postedAt),
                "postedAt should be ISO-8601, got \(first.postedAt)",
            )
        }

        /// End-to-end wire check for the effective-settings readback: build an
        /// AppState on an isolated settings suite, tweak a few values across
        /// sub-objects, project through the REAL `AppState.rpcStateSnapshot()`,
        /// and assert `GET /state.settings` returns them over a real socket.
        /// This is the surface E2E drivers use to confirm a blind `defaults
        /// write` actually took effect (`defaults read` is unreliable for the
        /// dev bundle's container-plist redirect).
        func testStateExposesEffectiveSettings() async throws {
            let suite = "DebugRPCServerIntegrationTests-\(getpid())-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.recordOnly = true
            settings.transcriptionEngine = .parakeet
            settings.numSpeakers = 4
            settings.diarizerMode = .sortformer
            // Deliberately NOT liveTranscriptionEnabled: with it on,
            // AppState.init's prewarm builds the real live-transcription
            // controller and kicks off actual CoreML/VAD model loads (network
            // download on a cold CI runner) in an unawaited background Task.
            settings.vadEnabled = true
            let state = AppState(settings: settings)
            defer { state.liveCaptions.clear() }

            let base = try await startServer(snapshot: state.rpcStateSnapshot())
            let (data, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("state"), headers: authHeader),
            )

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(RPCStateSnapshot.self, from: data)
            XCTAssertTrue(decoded.settings.recording.recordOnly)
            XCTAssertTrue(decoded.settings.diarization.vadEnabled)
            XCTAssertEqual(decoded.settings.transcription.engine, "parakeet")
            XCTAssertEqual(decoded.settings.diarization.numSpeakers, 4)
            XCTAssertEqual(decoded.settings.diarization.mode, "sortformer")
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

        // MARK: - /v1/jobs

        func testV1JobStatusReturnsJSON() async throws {
            let id = UUID()
            let dto = JobStatusDTO(
                jobID: id.uuidString, state: .done, meetingTitle: "Synced Call",
                transcriptPath: "/out/call.txt", protocolPath: "/out/call.md",
                error: nil, warnings: ["Mic track diarization failed"],
            )
            let lookup: (UUID) -> JobStatusDTO? = { $0 == id ? dto : nil }
            let base = try await startServer(jobStatus: lookup)

            let (data, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("v1/jobs/\(id.uuidString)"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(JobStatusDTO.self, from: data)
            XCTAssertEqual(decoded.state, .done)
            XCTAssertEqual(decoded.transcriptPath, "/out/call.txt")
            XCTAssertEqual(decoded.protocolPath, "/out/call.md")
            // Also exercises the full status contract round-trip (error + warnings),
            // which the live job-status response carries.
            XCTAssertNil(decoded.error)
            XCTAssertEqual(decoded.warnings, ["Mic track diarization failed"])
        }

        func testV1JobStatusUnknownIDReturns404() async throws {
            // Default jobStatus closure already returns nil for every ID.
            let base = try await startServer()
            let (_, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("v1/jobs/\(UUID().uuidString)"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }

        func testV1JobStatusIgnoresQueryString() async throws {
            let id = UUID()
            let dto = JobStatusDTO(
                jobID: id.uuidString, state: .done, meetingTitle: "Q",
                transcriptPath: nil, protocolPath: nil, error: nil, warnings: [],
            )
            let lookup: (UUID) -> JobStatusDTO? = { $0 == id ? dto : nil }
            let base = try await startServer(jobStatus: lookup)

            let url = try XCTUnwrap(URL(string: "\(base.absoluteString)/v1/jobs/\(id.uuidString)?wait=1"))
            let (_, response) = try await URLSession.shared.data(for: request("GET", url, headers: authHeader))
            XCTAssertEqual(
                (response as? HTTPURLResponse)?.statusCode, 200,
                "A query string must not turn a valid job ID into a 404",
            )
        }

        func testV1JobStatusMalformedIDReturns404() async throws {
            let base = try await startServer()
            let (_, response) = try await URLSession.shared.data(
                for: request("GET", base.appendingPathComponent("v1/jobs/not-a-uuid"), headers: authHeader),
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }

        func testV1EnqueueReturnsJobIDs() async throws {
            struct EnqueueResult: Decodable { let jobIDs: [String] }
            let ids = [UUID(), UUID()]
            let enqueue: ([URL]) -> [UUID] = { _ in ids }
            let base = try await startServer(enqueueReturningIDs: enqueue)

            var req = request("POST", base.appendingPathComponent("v1/jobs"), headers: authHeader)
            req.httpBody = Data(#"{"paths":["/inbox/a.wav","/inbox/b.wav"]}"#.utf8)
            let (data, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(EnqueueResult.self, from: data)
            XCTAssertEqual(decoded.jobIDs, ids.map(\.uuidString))
        }

        func testV1EnqueueEmptyPathsReturns400() async throws {
            let base = try await startServer()
            var req = request("POST", base.appendingPathComponent("v1/jobs"), headers: authHeader)
            req.httpBody = Data(#"{"paths":[]}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        // MARK: - /v1/jobs/<id>/naming

        func testV1NamingStatusReturnsJSON() async throws {
            let id = UUID()
            let dto = NamingStatusDTO(
                jobID: id.uuidString, meetingTitle: "Q3 Sync",
                speakers: [.init(label: "Speaker 1", suggested: "Roman", speakingSeconds: 42)],
                participants: ["Alice"],
            )
            let lookup: (UUID) -> NamingStatusDTO? = { $0 == id ? dto : nil }
            let base = try await startServer(namingStatus: lookup)

            let url = base.appendingPathComponent("v1/jobs/\(id.uuidString)/naming")
            let (data, response) = try await URLSession.shared.data(for: request("GET", url, headers: authHeader))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(NamingStatusDTO.self, from: data)
            XCTAssertEqual(decoded.jobID, id.uuidString)
            XCTAssertEqual(decoded.meetingTitle, "Q3 Sync")
            XCTAssertEqual(decoded.participants, ["Alice"])
            XCTAssertEqual(decoded.speakers.first?.label, "Speaker 1")
            XCTAssertEqual(decoded.speakers.first?.suggested, "Roman")
            XCTAssertEqual(decoded.speakers.first?.speakingSeconds, 42)
        }

        func testV1NamingStatusUnknownReturns404() async throws {
            let base = try await startServer()
            let url = base.appendingPathComponent("v1/jobs/\(UUID().uuidString)/naming")
            let (_, response) = try await URLSession.shared.data(for: request("GET", url, headers: authHeader))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }

        func testV1ConfirmNamingForwardsMappingAndReturns200() async throws {
            let id = UUID()
            actor MappingBox {
                private(set) var received: [String: String] = [:]
                func record(_ m: [String: String]) {
                    received = m
                }
            }
            let box = MappingBox()
            let confirm: (UUID, [String: String]) -> Bool = { jobID, m in
                guard jobID == id else { return false }
                Task { await box.record(m) }
                return true
            }
            let base = try await startServer(confirmNaming: confirm)

            var req = request("POST", base.appendingPathComponent("v1/jobs/\(id.uuidString)/naming"), headers: authHeader)
            req.httpBody = Data(#"{"mapping":{"Speaker 1":"Roman"}}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

            var received: [String: String] = [:]
            for _ in 0 ..< 20 {
                received = await box.received
                if !received.isEmpty { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(received, ["Speaker 1": "Roman"])
        }

        func testV1ConfirmNamingUnknownReturns404() async throws {
            // Default confirmNaming closure returns false for every job → 404.
            let base = try await startServer()
            var req = request("POST", base.appendingPathComponent("v1/jobs/\(UUID().uuidString)/naming"), headers: authHeader)
            req.httpBody = Data(#"{"mapping":{}}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }

        func testV1ConfirmNamingMalformedBodyReturns400() async throws {
            let confirm: (UUID, [String: String]) -> Bool = { _, _ in true }
            let base = try await startServer(confirmNaming: confirm)
            var req = request("POST", base.appendingPathComponent("v1/jobs/\(UUID().uuidString)/naming"), headers: authHeader)
            req.httpBody = Data("{}".utf8) // missing "mapping"
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        func testV1SkipNamingReturns200() async throws {
            let id = UUID()
            let skip: (UUID) -> Bool = { $0 == id }
            let base = try await startServer(skipJobNaming: skip)
            let url = base.appendingPathComponent("v1/jobs/\(id.uuidString)/naming/skip")
            let (_, response) = try await URLSession.shared.data(for: request("POST", url, headers: authHeader))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }

        func testV1SkipNamingUnknownReturns404() async throws {
            let base = try await startServer()
            let url = base.appendingPathComponent("v1/jobs/\(UUID().uuidString)/naming/skip")
            let (_, response) = try await URLSession.shared.data(for: request("POST", url, headers: authHeader))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }

        /// A job that exists but isn't awaiting naming → confirm/skip is a
        /// state conflict (409), distinct from an unknown id (404).
        private func wrongStateStatus(_ id: UUID) -> (UUID) -> JobStatusDTO? {
            { jid in
                jid == id ? JobStatusDTO(
                    jobID: jid.uuidString, state: .transcribing, meetingTitle: "M",
                    transcriptPath: nil, protocolPath: nil, error: nil, warnings: [],
                ) : nil
            }
        }

        func testV1ConfirmNamingWrongStateReturns409() async throws {
            let id = UUID()
            // Default confirmNaming returns false; jobStatus says the job exists.
            let base = try await startServer(jobStatus: wrongStateStatus(id))
            var req = request("POST", base.appendingPathComponent("v1/jobs/\(id.uuidString)/naming"), headers: authHeader)
            req.httpBody = Data(#"{"mapping":{}}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 409)
        }

        func testV1SkipNamingWrongStateReturns409() async throws {
            let id = UUID()
            let base = try await startServer(jobStatus: wrongStateStatus(id))
            let url = base.appendingPathComponent("v1/jobs/\(id.uuidString)/naming/skip")
            let (_, response) = try await URLSession.shared.data(for: request("POST", url, headers: authHeader))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 409)
        }

        func testV1UnknownSubResourceOrMethodReturns404() async throws {
            let base = try await startServer()
            let id = UUID().uuidString
            // Wrong method on a real sub-resource, and an unknown sub-resource,
            // both fall through routeV1 to 404.
            let getSkip = base.appendingPathComponent("v1/jobs/\(id)/naming/skip") // skip is POST-only
            let (_, r1) = try await URLSession.shared.data(for: request("GET", getSkip, headers: authHeader))
            XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 404)

            let bogus = base.appendingPathComponent("v1/jobs/\(id)/bogus")
            let (_, r2) = try await URLSession.shared.data(for: request("GET", bogus, headers: authHeader))
            XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 404)
        }

        // MARK: - POST /v1/transcribe (blocking)

        func testV1TranscribeCompletedReturns200() async throws {
            let dto = JobStatusDTO(
                jobID: UUID().uuidString, state: .done, meetingTitle: "M",
                transcriptPath: "/out/t.txt", protocolPath: nil, error: nil, warnings: [],
            )
            let transcribe: (URL, Double) async -> BlockingTranscribeResult = { _, _ in await Task.yield(); return .completed(dto) }
            let base = try await startServer(transcribe: transcribe)

            var req = request("POST", base.appendingPathComponent("v1/transcribe"), headers: authHeader)
            req.httpBody = Data(#"{"path":"/inbox/a.wav"}"#.utf8)
            let (data, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(JobStatusDTO.self, from: data)
            XCTAssertEqual(decoded.state, .done)
            XCTAssertEqual(decoded.transcriptPath, "/out/t.txt")
        }

        func testV1TranscribeTimedOutReturns202() async throws {
            let dto = JobStatusDTO(
                jobID: UUID().uuidString, state: .transcribing, meetingTitle: "M",
                transcriptPath: nil, protocolPath: nil, error: nil, warnings: [],
            )
            let transcribe: (URL, Double) async -> BlockingTranscribeResult = { _, _ in await Task.yield(); return .timedOut(dto) }
            let base = try await startServer(transcribe: transcribe)

            var req = request("POST", base.appendingPathComponent("v1/transcribe"), headers: authHeader)
            req.httpBody = Data(#"{"path":"/inbox/a.wav","maxWaitSeconds":1}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 202)
        }

        func testV1TranscribeNoFileReturns400() async throws {
            let transcribe: (URL, Double) async -> BlockingTranscribeResult = { _, _ in await Task.yield(); return .noFile }
            let base = try await startServer(transcribe: transcribe)

            var req = request("POST", base.appendingPathComponent("v1/transcribe"), headers: authHeader)
            req.httpBody = Data(#"{"path":"/inbox/missing.wav"}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        func testV1TranscribeEmptyPathReturns400() async throws {
            let base = try await startServer()
            var req = request("POST", base.appendingPathComponent("v1/transcribe"), headers: authHeader)
            req.httpBody = Data(#"{"path":""}"#.utf8)
            let (_, response) = try await URLSession.shared.upload(for: req, from: XCTUnwrap(req.httpBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }

        // MARK: - Idempotency-Key

        private func idempotentHeaders(_ key: String) -> [String: String] {
            authHeader.merging(["Idempotency-Key": key]) { _, new in new }
        }

        func testV1JobsIdempotencyKeyReturnsSameJobsWithoutNewEnqueue() async throws {
            // enqueue yields a fresh id every call → identical responses can only
            // mean the second request was served from the idempotency store.
            let enqueue: ([URL]) -> [UUID] = { _ in [UUID()] }
            let base = try await startServer(enqueueReturningIDs: enqueue)
            let url = base.appendingPathComponent("v1/jobs")
            let body = Data(#"{"paths":["/inbox/a.wav"]}"#.utf8)
            let hdrs = idempotentHeaders("jobs-key-1")

            var req1 = request("POST", url, headers: hdrs); req1.httpBody = body
            let (d1, r1) = try await URLSession.shared.upload(for: req1, from: body)
            var req2 = request("POST", url, headers: hdrs); req2.httpBody = body
            let (d2, r2) = try await URLSession.shared.upload(for: req2, from: body)

            XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 200)
            struct EnqueueIDs: Decodable { let jobIDs: [String] }
            let ids1 = try JSONDecoder().decode(EnqueueIDs.self, from: d1).jobIDs
            let ids2 = try JSONDecoder().decode(EnqueueIDs.self, from: d2).jobIDs
            XCTAssertFalse(ids1.isEmpty)
            XCTAssertEqual(ids1, ids2, "same Idempotency-Key returns the original jobIDs, no new job")
        }

        func testV1JobsDifferentKeysEnqueueSeparately() async throws {
            let enqueue: ([URL]) -> [UUID] = { _ in [UUID()] }
            let base = try await startServer(enqueueReturningIDs: enqueue)
            let url = base.appendingPathComponent("v1/jobs")
            let body = Data(#"{"paths":["/inbox/a.wav"]}"#.utf8)

            var req1 = request("POST", url, headers: idempotentHeaders("k-a")); req1.httpBody = body
            let (d1, _) = try await URLSession.shared.upload(for: req1, from: body)
            var req2 = request("POST", url, headers: idempotentHeaders("k-b")); req2.httpBody = body
            let (d2, _) = try await URLSession.shared.upload(for: req2, from: body)

            struct EnqueueIDs: Decodable { let jobIDs: [String] }
            let ids1 = try JSONDecoder().decode(EnqueueIDs.self, from: d1).jobIDs
            let ids2 = try JSONDecoder().decode(EnqueueIDs.self, from: d2).jobIDs
            XCTAssertNotEqual(ids1, ids2, "distinct keys create distinct jobs")
        }

        func testV1JobsIdempotencyRemembersEmptyResult() async throws {
            // An enqueue that matched no files stores [] under the key. A retry
            // must return that [] from the store, not treat the empty result as
            // "key unseen" and re-enqueue (the nil-vs-[] distinction the store
            // documents). The enqueue yields [] first and a fresh id after, so a
            // wrongful re-enqueue would surface that id on the retry.
            let sequencer = EnqueueSequencer()
            // Typed local (not a trailing closure) so SwiftFormat can't restyle
            // it into a trailing closure that binds to the wrong parameter.
            let enqueue: ([URL]) -> [UUID] = { _ in sequencer.next() }
            let base = try await startServer(enqueueReturningIDs: enqueue)
            let url = base.appendingPathComponent("v1/jobs")
            let body = Data(#"{"paths":["/inbox/a.wav"]}"#.utf8)
            let hdrs = idempotentHeaders("jobs-empty-key")

            var req1 = request("POST", url, headers: hdrs); req1.httpBody = body
            let (d1, r1) = try await URLSession.shared.upload(for: req1, from: body)
            var req2 = request("POST", url, headers: hdrs); req2.httpBody = body
            let (d2, r2) = try await URLSession.shared.upload(for: req2, from: body)

            XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 200)
            struct EnqueueIDs: Decodable { let jobIDs: [String] }
            let ids1 = try JSONDecoder().decode(EnqueueIDs.self, from: d1).jobIDs
            let ids2 = try JSONDecoder().decode(EnqueueIDs.self, from: d2).jobIDs
            XCTAssertEqual(ids1, [], "first enqueue matched no files → empty result")
            XCTAssertEqual(ids2, [], "retry with the same key returns the stored empty result, no re-enqueue")
        }

        // MARK: - transcribe wait clamping

        func testV1TranscribeClampsAndDefaultsWait() async throws {
            // The blocking-transcribe wait is min(max(0, requested), 1800) with a
            // 600s default. Record the value the transcribe closure actually
            // receives and assert all three boundary points.
            let recorder = WaitRecorder()
            let dto = JobStatusDTO(
                jobID: UUID().uuidString, state: .done, meetingTitle: "M",
                transcriptPath: "/out/t.txt", protocolPath: nil, error: nil, warnings: [],
            )
            // Bind the closure to a typed local (not a trailing closure) so its
            // two-arg shape can't be mis-inferred against the sibling 2-arg
            // confirmNaming parameter, and SwiftFormat can't restyle it.
            let transcribe: (URL, Double) async -> BlockingTranscribeResult = { _, wait in
                await recorder.record(wait)
                return .completed(dto)
            }
            let base = try await startServer(transcribe: transcribe)
            let url = base.appendingPathComponent("v1/transcribe")

            func postWait(_ jsonBody: String) async throws -> Double? {
                var req = request("POST", url, headers: authHeader)
                let payload = Data(jsonBody.utf8)
                req.httpBody = payload
                _ = try await URLSession.shared.upload(for: req, from: payload)
                return await recorder.last
            }

            let capped = try await postWait(#"{"path":"/inbox/a.wav","maxWaitSeconds":99999}"#)
            XCTAssertEqual(capped, 1800, "a maxWaitSeconds above the cap must clamp to 1800")
            let floored = try await postWait(#"{"path":"/inbox/a.wav","maxWaitSeconds":-5}"#)
            XCTAssertEqual(floored, 0, "a negative maxWaitSeconds must clamp to 0")
            let defaulted = try await postWait(#"{"path":"/inbox/a.wav"}"#)
            XCTAssertEqual(defaulted, 600, "an omitted maxWaitSeconds must use the 600s default")
        }

        // MARK: - V1 test helpers

        /// Sync, thread-safe enqueue stub: first call returns [] (no files
        /// matched), later calls return a fresh id. Lets a test prove the
        /// idempotency store dedups an empty result instead of re-enqueuing.
        private final class EnqueueSequencer: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func next() -> [UUID] {
                lock.lock()
                defer { lock.unlock() }
                calls += 1
                return calls == 1 ? [] : [UUID()]
            }
        }

        /// Records the wait the transcribe closure was last invoked with.
        private actor WaitRecorder {
            private(set) var last: Double?
            func record(_ value: Double) {
                last = value
            }
        }

        func testV1TranscribeIdempotencyKeyReturnsExistingJobWithoutReRun() async throws {
            // transcribe yields a fresh job each call; the repeat path instead
            // resolves the stored id via jobStatus (echoed here), so identical
            // jobIDs prove the second request did not re-run transcribe.
            let transcribe: (URL, Double) async -> BlockingTranscribeResult = { _, _ in
                await Task.yield()
                return .completed(JobStatusDTO(
                    jobID: UUID().uuidString, state: .done, meetingTitle: "M",
                    transcriptPath: "/out/t.txt", protocolPath: nil, error: nil, warnings: [],
                ))
            }
            let status: (UUID) -> JobStatusDTO? = { id in
                JobStatusDTO(
                    jobID: id.uuidString, state: .done, meetingTitle: "M",
                    transcriptPath: "/out/t.txt", protocolPath: nil, error: nil, warnings: [],
                )
            }
            let base = try await startServer(jobStatus: status, transcribe: transcribe)
            let url = base.appendingPathComponent("v1/transcribe")
            let body = Data(#"{"path":"/inbox/a.wav"}"#.utf8)
            let hdrs = idempotentHeaders("tx-key-1")

            var req1 = request("POST", url, headers: hdrs); req1.httpBody = body
            let (d1, r1) = try await URLSession.shared.upload(for: req1, from: body)
            var req2 = request("POST", url, headers: hdrs); req2.httpBody = body
            let (d2, r2) = try await URLSession.shared.upload(for: req2, from: body)

            XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 200)
            let j1 = try JSONDecoder().decode(JobStatusDTO.self, from: d1).jobID
            let j2 = try JSONDecoder().decode(JobStatusDTO.self, from: d2).jobID
            XCTAssertEqual(j1, j2, "repeat returns the same job via the idempotency store, no re-run")
        }

        // MARK: - POST /v1/transcribe?include=transcript (inline text)

        /// Issue #431: a headless remote consumer with no shared filesystem
        /// can't read `transcriptPath`. `?include=transcript` inlines the file's
        /// text into the response body so the agent gets the transcript directly.
        func testV1TranscribeIncludeTranscriptInlinesFileText() async throws {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("mt-inline-\(UUID().uuidString).txt")
            let text = "[00:00] S1: Hallo, dies ist ein Test.\n[00:04] S2: Alles klar."
            try Data(text.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let dto = JobStatusDTO(
                jobID: UUID().uuidString, state: .done, meetingTitle: "M",
                transcriptPath: file.path, protocolPath: nil, error: nil, warnings: [],
            )
            let transcribe: (URL, Double) async -> BlockingTranscribeResult = { _, _ in
                await Task.yield(); return .completed(dto)
            }
            let base = try await startServer(transcribe: transcribe)

            let url = try XCTUnwrap(URL(string: "\(base.absoluteString)/v1/transcribe?include=transcript"))
            var req = request("POST", url, headers: authHeader)
            let body = Data(#"{"path":"/inbox/a.wav"}"#.utf8)
            req.httpBody = body
            let (data, response) = try await URLSession.shared.upload(for: req, from: body)

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let decoded = try JSONDecoder().decode(JobStatusResponse.self, from: data)
            XCTAssertEqual(decoded.transcript, text)
            XCTAssertEqual(decoded.status.transcriptPath, file.path, "the path stays alongside the inline text")
        }

        /// Without the opt-in, the response is metadata-only — no `transcript`
        /// key at all, so the default wire shape is unchanged.
        func testV1TranscribeWithoutIncludeOmitsTranscript() async throws {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("mt-inline-\(UUID().uuidString).txt")
            try Data("[00:00] S1: text".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let dto = JobStatusDTO(
                jobID: UUID().uuidString, state: .done, meetingTitle: "M",
                transcriptPath: file.path, protocolPath: nil, error: nil, warnings: [],
            )
            let transcribe: (URL, Double) async -> BlockingTranscribeResult = { _, _ in
                await Task.yield(); return .completed(dto)
            }
            let base = try await startServer(transcribe: transcribe)

            var req = request("POST", base.appendingPathComponent("v1/transcribe"), headers: authHeader)
            let body = Data(#"{"path":"/inbox/a.wav"}"#.utf8)
            req.httpBody = body
            let (data, response) = try await URLSession.shared.upload(for: req, from: body)

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(raw.contains("\"transcript\""), "no include → no inline transcript key: \(raw)")
        }

        /// The poll-based flow (`GET /v1/jobs/<id>`) supports the same opt-in.
        func testV1JobStatusIncludeTranscriptInlinesFileText() async throws {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("mt-inline-\(UUID().uuidString).txt")
            let text = "[00:00] S1: polled transcript"
            try Data(text.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let id = UUID()
            let dto = JobStatusDTO(
                jobID: id.uuidString, state: .done, meetingTitle: "M",
                transcriptPath: file.path, protocolPath: nil, error: nil, warnings: [],
            )
            let lookup: (UUID) -> JobStatusDTO? = { $0 == id ? dto : nil }
            let base = try await startServer(jobStatus: lookup)

            let url = try XCTUnwrap(URL(string: "\(base.absoluteString)/v1/jobs/\(id.uuidString)?include=transcript"))
            let (data, response) = try await URLSession.shared.data(for: request("GET", url, headers: authHeader))

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(try JSONDecoder().decode(JobStatusResponse.self, from: data).transcript, text)
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
