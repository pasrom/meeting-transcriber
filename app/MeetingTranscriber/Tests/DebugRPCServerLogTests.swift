#if !APPSTORE
    @testable import MeetingTranscriber
    import os
    import XCTest

    /// `GET /log`: the debug route that hands a driver script the app's own
    /// recent unified-log entries, so a driver script can read the capture
    /// log over the API instead of through `log show`.
    final class DebugRPCServerLogTests: XCTestCase {
        private static let token = "log-route-token"
        private static let auth = ["authorization": "Bearer \(token)"]

        // MARK: - Query parsing

        func testNoQueryUsesTheDefaults() {
            XCTAssertEqual(
                RPCLogQuery.parse(target: "/log"),
                RPCLogQuery(sinceSeconds: RPCLogQuery.defaultSinceSeconds, limit: RPCLogQuery.defaultLimit),
            )
        }

        func testSinceAndLimitAreRead() {
            XCTAssertEqual(
                RPCLogQuery.parse(target: "/log?since=120&limit=50"),
                RPCLogQuery(sinceSeconds: 120, limit: 50),
            )
            XCTAssertEqual(RPCLogQuery.parse(target: "/log?limit=7")?.sinceSeconds, RPCLogQuery.defaultSinceSeconds)
            XCTAssertEqual(RPCLogQuery.parse(target: "/log?since=1.5")?.sinceSeconds, 1.5)
            XCTAssertEqual(RPCLogQuery.parse(target: "/log?since=0")?.sinceSeconds, 0)
        }

        func testALimitAboveTheCapIsClampedToIt() {
            XCTAssertEqual(RPCLogQuery.parse(target: "/log?limit=999999")?.limit, RPCLogQuery.maxLimit)
        }

        func testMalformedParametersAreRefused() {
            for target in [
                "/log?since=-1", "/log?since=abc", "/log?since=nan", "/log?since=inf",
                "/log?limit=0", "/log?limit=-3", "/log?limit=x", "/log?limit=1.5",
                "/log?limit=99999999999999999999",
            ] {
                XCTAssertNil(RPCLogQuery.parse(target: target), target)
            }
        }

        // MARK: - Selection

        func testOnlyTheAppsOwnSubsystemsAreKept() {
            let now = Date()
            let entries = [
                entry("app", at: now, subsystem: "com.meetingtranscriber"),
                entry("capture", at: now, subsystem: "com.meetingtranscriber.audiotap"),
                entry("lookalike", at: now, subsystem: "com.meetingtranscriberx"),
                entry("framework", at: now, subsystem: "com.apple.coreaudio"),
                entry("none", at: now, subsystem: ""),
            ]
            let selected = collect(entries, since: now.addingTimeInterval(-60), limit: 100)
            XCTAssertEqual(selected.entries.map(\.message), ["app", "capture"])
            XCTAssertFalse(selected.truncated)
        }

        func testEntriesBeforeSinceAreDropped() {
            let now = Date()
            let entries = [
                entry("old", at: now.addingTimeInterval(-600)),
                entry("edge", at: now.addingTimeInterval(-60)),
                entry("new", at: now),
            ]
            let selected = collect(entries, since: now.addingTimeInterval(-60), limit: 100)
            XCTAssertEqual(selected.entries.map(\.message), ["edge", "new"])
        }

        func testTheLimitKeepsTheNewestEntriesInOrderAndSaysItCut() {
            let now = Date()
            let entries = (0 ..< 5).map { entry("e\($0)", at: now.addingTimeInterval(Double($0))) }
            let selected = collect(entries, since: now.addingTimeInterval(-60), limit: 2)
            XCTAssertEqual(selected.entries.map(\.message), ["e3", "e4"])
            XCTAssertTrue(selected.truncated)

            let exact = collect(entries, since: now.addingTimeInterval(-60), limit: 5)
            XCTAssertEqual(exact.entries.count, 5)
            XCTAssertFalse(exact.truncated, "exactly limit entries is not a cut")
        }

        /// Foreign entries do not count towards the limit, or a chatty framework
        /// could push the app's own lines out of the response.
        func testForeignEntriesDoNotUseUpTheLimit() {
            let now = Date()
            let entries = [
                entry("mine", at: now),
                entry("theirs-1", at: now, subsystem: "com.apple.x"),
                entry("theirs-2", at: now, subsystem: "com.apple.x"),
            ]
            let selected = collect(entries, since: now.addingTimeInterval(-60), limit: 1)
            XCTAssertEqual(selected.entries.map(\.message), ["mine"])
            XCTAssertFalse(selected.truncated)
        }

        /// The reader walks every entry since the cutoff, and the collector
        /// drops its older half each time it reaches `2 * limit`. Checked at
        /// every count across many of those drops, so a drop that cuts too
        /// much shows in the response. One that cuts too little, or no drop
        /// at all, leaves the response unchanged; the `assert` in
        /// `RPCLogCollector.add` traps on that here, in a debug build.
        func testTheNewestEntriesSurviveEveryDropOfTheOlderHalf() {
            let now = Date()
            let limit = 3
            var collector = RPCLogCollector(since: now.addingTimeInterval(-60), limit: limit)
            for index in 0 ..< 1000 {
                collector.add(entry("e\(index)", at: now.addingTimeInterval(Double(index) / 1000)))
                let response = collector.response
                let expected = (max(0, index + 1 - limit) ... index).map { "e\($0)" }
                XCTAssertEqual(response.entries.map(\.message), expected, "after \(index + 1) entries")
                XCTAssertEqual(response.truncated, index + 1 > limit, "after \(index + 1) entries")
            }
        }

        // MARK: - Route

        @MainActor
        func testRouteReturnsTheSelectedEntriesAsJSON() async throws {
            let now = Date()
            let reader = RecordingReader(entries: [
                entry("too old", at: now.addingTimeInterval(-3600)),
                entry("foreign", at: now, subsystem: "com.apple.x"),
                entry("Mic recording started", at: now, subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture"),
            ])
            let server = makeServer(reader)

            let response = await server.route(get("/log?since=60&limit=10"))

            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.contentType, "application/json")
            let body = try decode(response)
            XCTAssertFalse(body.truncated)
            XCTAssertEqual(body.entries.map(\.message), ["Mic recording started"])
            XCTAssertEqual(body.entries.first?.subsystem, "com.meetingtranscriber.audiotap")
            XCTAssertEqual(body.entries.first?.category, "MicCapture")
            XCTAssertEqual(body.entries.first?.level, "info")
            XCTAssertNotNil(body.entries.first.flatMap { Self.parseDate($0.date) }, "date is ISO 8601")
        }

        @MainActor
        func testRouteAppliesTheRequestsLimit() async throws {
            let now = Date()
            let reader = RecordingReader(entries: (0 ..< 5).map { entry("e\($0)", at: now) })
            let server = makeServer(reader)

            let response = await server.route(get("/log?limit=2"))
            let body = try decode(response)

            XCTAssertEqual(body.entries.map(\.message), ["e3", "e4"])
            XCTAssertTrue(body.truncated)
        }

        @MainActor
        func testRouteHandsTheReaderACutoffSinceSecondsAgo() async throws {
            let reader = RecordingReader(entries: [])
            let server = makeServer(reader)
            let before = Date()

            _ = await server.route(get("/log?since=120"))

            let call = try XCTUnwrap(reader.calls.first)
            XCTAssertEqual(call.since.timeIntervalSince(before), -120, accuracy: 5)
        }

        /// A client that gives up does not cancel its store walk, so a second
        /// request while one runs is refused rather than stacked; once the
        /// first finishes, reads are allowed again. Every wait is bounded: a
        /// parked read gives up after `Gate.timeout` and answers 503, so a
        /// broken guard fails this test instead of hanging the suite.
        @MainActor
        func testASecondReadWhileOneRunsIsRefused() async {
            let gate = Gate()
            defer { gate.open() }
            let reader = RecordingReader(entries: [], gate: gate)
            let server = makeServer(reader)

            let first = Task { await server.route(get("/log")) }
            await waitFor { !reader.calls.isEmpty }
            guard !reader.calls.isEmpty else {
                gate.open()
                _ = await first.value
                XCTFail("the first read never reached the store")
                return
            }
            let second = await server.route(get("/log"))
            gate.open()
            let firstResponse = await first.value
            let third = await server.route(get("/log"))

            XCTAssertEqual(second.status, 429)
            XCTAssertEqual(firstResponse.status, 200)
            XCTAssertEqual(third.status, 200, "the guard is released after a read")
            XCTAssertEqual(reader.calls.count, 2, "the refused request did not read the store")
        }

        /// `OSLogStore.getEntries` can take seconds over a long-running process;
        /// on the main actor that would freeze the app's UI for as long.
        @MainActor
        func testTheReaderRunsOffTheMainThread() async throws {
            let reader = RecordingReader(entries: [])
            let server = makeServer(reader)

            _ = await server.route(get("/log"))

            let call = try XCTUnwrap(reader.calls.first)
            XCTAssertFalse(call.onMainThread, "the log store was read on the main thread")
        }

        @MainActor
        func testAMalformedQueryIsA400AndDoesNotReadTheLog() async {
            let reader = RecordingReader(entries: [])
            let server = makeServer(reader)

            let response = await server.route(get("/log?limit=0"))

            XCTAssertEqual(response.status, 400)
            XCTAssertTrue(reader.calls.isEmpty)
        }

        @MainActor
        func testAFailingLogStoreIsA503() async {
            // A description can carry a path with the user name in it; the 503
            // names only the domain and the code.
            let marker = "/Users/marker-user/Library/Logs/marker.logarchive"
            let failure = NSError(
                domain: "OSLogErrorDomain", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "cannot open \(marker)"],
            )
            let reader = RecordingReader(entries: [], failure: failure)
            let server = makeServer(reader)

            let response = await server.route(get("/log"))

            XCTAssertEqual(response.status, 503)
            let text = String(bytes: response.body, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("OSLogErrorDomain"), text)
            XCTAssertTrue(text.contains("code 9"), text)
            XCTAssertFalse(text.contains("marker-user"), text)
        }

        @MainActor
        func testTheRouteNeedsTheToken() async {
            let reader = RecordingReader(entries: [])
            let server = makeServer(reader)

            let missing = await server.route(HTTPRequest(method: "GET", path: "/log"))
            let wrong = await server.route(HTTPRequest(
                method: "GET", path: "/log", headers: ["authorization": "Bearer nope"],
            ))

            XCTAssertEqual(missing.status, 401)
            XCTAssertEqual(wrong.status, 401)
            XCTAssertTrue(reader.calls.isEmpty, "the log was read for an unauthenticated request")
        }

        @MainActor
        func testTheRouteRefusesABrowser() async {
            let reader = RecordingReader(entries: [])
            let server = makeServer(reader)
            var headers = Self.auth
            headers["origin"] = "https://example.com"

            let response = await server.route(HTTPRequest(method: "GET", path: "/log", headers: headers))

            XCTAssertEqual(response.status, 403)
            XCTAssertTrue(reader.calls.isEmpty)
        }

        @MainActor
        func testOnlyGETIsRouted() async {
            let reader = RecordingReader(entries: [])
            let server = makeServer(reader)

            let response = await server.route(HTTPRequest(method: "POST", path: "/log", headers: Self.auth))

            XCTAssertEqual(response.status, 404)
            XCTAssertTrue(reader.calls.isEmpty)
        }

        /// Kept off the `/v1` contract: log lines can carry meeting titles.
        @MainActor
        func testTheRouteIsNotUnderV1() async {
            let reader = RecordingReader(entries: [])
            let server = makeServer(reader)

            let response = await server.route(get("/v1/log"))

            XCTAssertEqual(response.status, 404)
            XCTAssertTrue(reader.calls.isEmpty)
        }

        // MARK: - The production reader

        /// A server built without a reader, as `AppState` builds it, reads the
        /// real `OSLogStore` of this process: a line this process just logged
        /// under the app's subsystem comes back and one logged under a foreign
        /// subsystem does not. Polled, up to a deadline, because the store
        /// takes the entry asynchronously. A private interpolation comes back
        /// redacted, which is what keeps `GET /log` from handing out what a
        /// call site marked private; a Mac with private logging switched on
        /// by a configuration profile would fail that assertion.
        ///
        /// Skipped only on a self-hosted CI runner, and there only on a 503
        /// naming Swift's `nilError`. The route answered 503 once on that
        /// runner (non-admin account, under AddressSanitizer, Quality & Safety
        /// run 44952578295); the cause is not isolated, and that run did not
        /// print the body, so the domain and code are inferred, not observed.
        /// `nilError` is what an Objective-C call that returns nil without an
        /// error becomes, and it bridges to error domain
        /// `Foundation._GenericObjCError`, code 0. Anywhere else, hosted
        /// runners and developer machines included, a 503 fails the test, so
        /// a reader that broke everywhere cannot pass as a skip.
        @MainActor
        func testTheDefaultServerReadsThisProcessesOwnLog() async throws {
            let server = DebugRPCServer(port: 0, token: Self.token) { .empty }
            let marker = "log-route-marker-\(UUID().uuidString)"
            let secret = "Speaker A \(UUID().uuidString)"
            Logger(subsystem: AppPaths.logSubsystem, category: "DebugRPCServerLogTests")
                .error("\(marker, privacy: .public) mine \(secret, privacy: .private)")
            Logger(subsystem: "com.example.foreign", category: "DebugRPCServerLogTests")
                .error("\(marker, privacy: .public) theirs")

            var found: [WireBody.Entry] = []
            // Generous: in a shard every poll walks all the process has logged.
            let deadline = Date().addingTimeInterval(30)
            while found.isEmpty, Date() < deadline {
                let response = await server.route(get("/log?since=30"))
                let body = String(bytes: response.body, encoding: .utf8) ?? ""
                if response.status == 503,
                   ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "self-hosted",
                   body.contains("error domain Foundation._GenericObjCError, code 0)") {
                    throw XCTSkip("this user cannot open its own log store: \(body.trimmingCharacters(in: .newlines))")
                }
                XCTAssertEqual(response.status, 200, body)
                found = try decode(response).entries.filter { $0.message.contains(marker) }
                if found.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            }
            XCTAssertEqual(found.map(\.message), ["\(marker) mine <private>"])
            XCTAssertEqual(found.first?.subsystem, AppPaths.logSubsystem)
            XCTAssertEqual(found.first?.category, "DebugRPCServerLogTests")
            XCTAssertEqual(found.first?.level, "error")
        }

        // MARK: - Helpers

        /// Field-for-field mirror of the wire shape, `date` as the raw string.
        private struct WireBody: Decodable {
            struct Entry: Decodable {
                let date: String
                let level: String
                let subsystem: String
                let category: String
                let message: String
            }

            let entries: [Entry]
            let truncated: Bool
        }

        private static func parseDate(_ string: String) -> Date? {
            try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }

        private func decode(_ response: HTTPResponse) throws -> WireBody {
            try JSONDecoder().decode(WireBody.self, from: response.body)
        }

        private func get(_ path: String) -> HTTPRequest {
            HTTPRequest(method: "GET", path: path, headers: Self.auth)
        }

        @MainActor
        private func makeServer(_ reader: RecordingReader) -> DebugRPCServer {
            DebugRPCServer(port: 0, token: Self.token, snapshot: { .empty }, logReader: reader.read)
        }

        /// What the route returns for `entries` handed over by a reader.
        private func collect(_ entries: [RPCLogEntry], since: Date, limit: Int) -> RPCLogResponse {
            var collector = RPCLogCollector(since: since, limit: limit)
            entries.forEach { collector.add($0) }
            return collector.response
        }

        private func entry(
            _ message: String,
            at date: Date,
            subsystem: String = AppPaths.logSubsystem,
            category: String = "Test",
        ) -> RPCLogEntry {
            RPCLogEntry(date: date, level: "info", subsystem: subsystem, category: category, message: message)
        }
    }

    /// Closed until `open()`, then open for good. `wait()` gives up after
    /// `timeout` and says so, so no test can park a read forever.
    private final class Gate: Sendable {
        static let timeout: DispatchTimeInterval = .seconds(5)
        private let group = DispatchGroup()
        private let isOpen = OSAllocatedUnfairLock(initialState: false)

        init() {
            group.enter()
        }

        func open() {
            let wasOpen = isOpen.withLock { open in
                defer { open = true }
                return open
            }
            if !wasOpen { group.leave() }
        }

        /// false when the gate was still closed after `timeout`.
        func wait() -> Bool {
            group.wait(timeout: .now() + Self.timeout) == .success
        }
    }

    /// A `LogReader` that answers from a fixed list and records each call:
    /// the cutoff it was given and whether it ran on the main thread. With
    /// a `gate`, each read waits for it to open, and fails if it does not
    /// open in time.
    private final class RecordingReader: Sendable {
        struct Call {
            let since: Date
            let onMainThread: Bool
        }

        private let entries: [RPCLogEntry]
        private let failure: NSError?
        private let gate: Gate?
        private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])

        init(entries: [RPCLogEntry], failure: NSError? = nil, gate: Gate? = nil) {
            self.entries = entries
            self.failure = failure
            self.gate = gate
        }

        var calls: [Call] {
            recorded.withLock { $0 }
        }

        var read: DebugRPCServer.LogReader {
            { [self] since, visit in
                let call = Call(since: since, onMainThread: Thread.isMainThread)
                recorded.withLock { $0.append(call) }
                if let gate, !gate.wait() { throw NSError(domain: "RecordingReader.gateTimedOut", code: 1) }
                if let failure { throw failure }
                entries.forEach(visit)
            }
        }
    }
#endif
