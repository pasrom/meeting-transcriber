// swiftlint:disable file_length
@testable import MeetingTranscriber
import XCTest

@MainActor
final class AppStateTests: XCTestCase { // swiftlint:disable:this type_body_length
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testLogDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Per-test isolated logDir for the PipelineQueue snapshot file.
        // Without it, concurrent test methods (xctest spawns a subprocess
        // per method under `--parallel`) race on the production
        // `AppPaths.ipcDir/pipeline_queue.json`, leaking jobs across
        // tests as `count == 2` where `count == 1` is expected.
        testLogDir = try makeTempDirectory(prefix: "AppStateTests")
    }

    // MARK: - Helpers

    private func makeState() -> (AppState, RecordingNotifier) {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        // Inject a PipelineQueue with mocks + the per-test isolated logDir.
        // The engine != nil arm short-circuits `pipeline.ensureQueue()` so
        // it doesn't replace our queue with one wired to the production
        // `AppPaths.ipcDir` path on the first `enqueueFiles` call.
        state.pipeline.queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: testLogDir,
            logDir: testLogDir,
        )
        return (state, notifier)
    }

    /// AppState with a caller-provided logDir. Use when a test wants to
    /// inspect snapshot contents at a known path; otherwise prefer
    /// `makeState()` which uses the per-test isolated `testLogDir`.
    private func makeIsolatedState(logDir: URL) -> (AppState, RecordingNotifier) {
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.pipeline.queue = PipelineQueue(logDir: logDir)
        return (state, notifier)
    }

    private func makeJob(title: String = "Sprint Review") -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "TestApp",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }

    // MARK: - Default State

    func testIsWatchingFalseWhenNoWatchLoop() {
        let (state, _) = makeState()
        XCTAssertFalse(state.isWatching)
    }

    func testCurrentStateLabelIdleByDefault() {
        let (state, _) = makeState()
        XCTAssertEqual(state.currentStateLabel, "Idle")
    }

    func testCurrentBadgeInactiveByDefault() {
        let (state, _) = makeState()
        XCTAssertEqual(state.currentBadge, .inactive)
    }

    func testCurrentStatusNilWhenNoWatchLoop() {
        let (state, _) = makeState()
        XCTAssertNil(state.currentStatus)
    }

    // MARK: - isWatching

    func testIsWatchingTrueWhenLoopActiveNotManual() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertTrue(state.isWatching)
    }

    func testIsWatchingFalseWhenLoopNotStarted() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        // loop not started → isActive == false
        XCTAssertFalse(state.isWatching)
    }

    func testIsWatchingFalseWhenManualRecording() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertFalse(state.isWatching)
    }

    // MARK: - currentStateLabel

    func testCurrentStateLabelWatchingWhenLoopActive() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertEqual(state.currentStateLabel, "Watching for Meetings...")
    }

    func testCurrentStateLabelRecordingWhenManualRecording() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertEqual(state.currentStateLabel, "Recording")
    }

    func testCurrentStateLabelIdleWhenLoopStopped() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.start()
        loop.stop()
        state.watching.watchLoop = nil
        XCTAssertEqual(state.currentStateLabel, "Idle")
    }

    // MARK: - currentStatus

    func testCurrentStatusNilWhenLoopNotStarted() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        XCTAssertNil(state.currentStatus)
    }

    func testCurrentStatusNotNilWhenLoopActive() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertNotNil(state.currentStatus)
    }

    func testCurrentStatusStateMatchesLoopTranscriberState() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertEqual(state.currentStatus?.state, .watching)
    }

    func testCurrentStatusDetailMatchesLoopDetail() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertEqual(state.currentStatus?.detail, "Polling for meetings...")
    }

    func testCurrentStatusMeetingNilWhenNoActiveMeeting() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.start()
        defer { loop.stop() }
        XCTAssertNil(state.currentStatus?.meeting)
    }

    func testCurrentStatusMeetingFromManualRecordingInfo() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
        defer { loop.stop() }
        let status = try XCTUnwrap(state.currentStatus)
        XCTAssertEqual(status.meeting?.app, "Chrome")
        XCTAssertEqual(status.meeting?.title, "Standup")
        XCTAssertEqual(status.meeting?.pid, 42)
    }

    // MARK: - currentBadge integration

    func testCurrentBadgeUpdateAvailableWithNoActivity() throws {
        let (state, _) = makeState()
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        state.updateChecker.availableUpdate = ReleaseInfo(
            tagName: "v9.9.9",
            name: "Test Release",
            prerelease: false,
            htmlURL: url,
            dmgURL: nil,
        )
        XCTAssertEqual(state.currentBadge, .updateAvailable)
    }

    func testCurrentBadgeRecordingWhenLoopRecording() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertEqual(state.currentBadge, .recording)
    }

    // MARK: - toggleWatching: stop path

    func testToggleWatchingStopsActiveLoop() {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        loop.start()
        state.watching.watchLoop = loop
        XCTAssertTrue(state.isWatching)

        state.watching.toggleWatching()

        XCTAssertNil(state.watching.watchLoop)
        XCTAssertFalse(state.isWatching)
    }

    func testToggleWatchingWhileManualRecordingIsNoOp() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        state.watching.toggleWatching() // must be a no-op

        XCTAssertNotNil(state.watching.watchLoop)
        XCTAssertEqual(state.watching.watchLoop?.isManualRecording, true)
    }

    // MARK: - toggleWatching: start path (async)

    // toggleWatching() spawns a Task { @MainActor }. We yield once to let it run.
    // In CI, Permissions.ensureMicrophoneAccess() returns false immediately (no bundle),
    // but toggleWatching() ignores the return value so WatchLoop is always created.

    func testToggleWatchingCreatesWatchLoop() async {
        let (state, _) = makeState()
        addTeardownBlock { state.watching.watchLoop?.stop() }

        // `AppState.init` does not expose the permission seams, so this is the
        // one path that reaches the production defaults. Auto-watch exercises
        // the same start without the optional Accessibility prompt, which would
        // otherwise be a real TCC call from a unit test.
        state.watching.toggleWatching(userInitiated: false)
        await waitFor(state.watching.watchLoop != nil)

        XCTAssertNotNil(state.watching.watchLoop)
    }

    func testToggleWatchingMakesLoopActive() async {
        let (state, _) = makeState()
        addTeardownBlock { state.watching.watchLoop?.stop() }

        state.watching.toggleWatching(userInitiated: false)
        await waitFor(state.watching.watchLoop?.isActive == true)

        XCTAssertEqual(state.watching.watchLoop?.isActive, true)
    }

    // MARK: - stopManualRecording

    func testStopManualRecordingClearsWatchLoop() async throws {
        let (state, _) = makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")

        state.watching.stopManualRecording()

        XCTAssertNil(state.watching.watchLoop)
    }

    func testStopManualRecordingWhenNoLoopIsNoOp() {
        let (state, _) = makeState()
        state.watching.stopManualRecording() // must not crash
        XCTAssertNil(state.watching.watchLoop)
    }

    // MARK: - enqueueFiles

    func testEnqueueFilesSingleURL() {
        let (state, _) = makeState()
        let url = URL(fileURLWithPath: "/tmp/sprint-review.wav")

        state.pipeline.enqueueFiles([url])

        XCTAssertEqual(state.pipeline.queue.jobs.count, 1)
    }

    func testEnqueueFilesMultipleURLs() {
        let (state, _) = makeState()
        let urls = (1 ... 3).map { URL(fileURLWithPath: "/tmp/meeting-\($0).wav") }

        state.pipeline.enqueueFiles(urls)

        XCTAssertEqual(state.pipeline.queue.jobs.count, 3)
    }

    func testEnqueueFilesTitleFromLastPathComponent() {
        let (state, _) = makeState()
        let url = URL(fileURLWithPath: "/tmp/sprint-review.wav")

        state.pipeline.enqueueFiles([url])

        XCTAssertEqual(state.pipeline.queue.jobs[0].meetingTitle, "sprint-review")
    }

    func testEnqueueFilesAppNameIsFile() {
        let (state, _) = makeState()
        state.pipeline.enqueueFiles([URL(fileURLWithPath: "/tmp/meeting.wav")])
        XCTAssertEqual(state.pipeline.queue.jobs[0].appName, "File")
    }

    func testEnqueueFilesEmptyArrayIsNoOp() {
        let (state, _) = makeState()
        state.pipeline.enqueueFiles([])
        XCTAssertTrue(state.pipeline.queue.jobs.isEmpty)
    }

    func testEnqueueFilesCreatesJobsWithNilAudioPaths() {
        let (state, _) = makeState()
        state.pipeline.enqueueFiles([URL(fileURLWithPath: "/tmp/meeting.wav")])
        XCTAssertNil(state.pipeline.queue.jobs[0].appPath)
        XCTAssertNil(state.pipeline.queue.jobs[0].micPath)
    }

    func testEnqueueFilesPairsTripletAsOneDualTrackJob() {
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/standup_app.wav"),
            URL(fileURLWithPath: "/tmp/standup_mic.wav"),
            URL(fileURLWithPath: "/tmp/standup_mix.wav"),
        ]

        state.pipeline.enqueueFiles(urls)

        XCTAssertEqual(state.pipeline.queue.jobs.count, 1)
        let job = state.pipeline.queue.jobs[0]
        XCTAssertEqual(job.mixPath?.lastPathComponent, "standup_mix.wav")
        XCTAssertEqual(job.appPath?.lastPathComponent, "standup_app.wav")
        XCTAssertEqual(job.micPath?.lastPathComponent, "standup_mic.wav")
    }

    func testEnqueueExistingFilesEmptyArrayReturnsZero() {
        let (state, _) = makeState()
        XCTAssertEqual(state.pipeline.enqueueExistingFiles([]), 0)
        XCTAssertTrue(state.pipeline.queue.jobs.isEmpty)
    }

    func testEnqueueExistingFilesAllMissingReturnsZeroAndDoesNotEnqueue() {
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/never-exists-\(UUID().uuidString).wav"),
            URL(fileURLWithPath: "/tmp/also-missing-\(UUID().uuidString).wav"),
        ]
        XCTAssertEqual(state.pipeline.enqueueExistingFiles(urls), 0)
        XCTAssertTrue(state.pipeline.queue.jobs.isEmpty)
    }

    func testEnqueueExistingFilesPartialExistenceForwardsOnlyExisting() throws {
        let (state, _) = makeState()
        let tmpDir = try makeTempDirectory(prefix: "enqueue-existing")
        let existing = tmpDir.appendingPathComponent("present.wav")
        let missing = tmpDir.appendingPathComponent("absent.wav")
        try Data("RIFF".utf8).write(to: existing)

        let count = state.pipeline.enqueueExistingFiles([existing, missing])

        XCTAssertEqual(count, 1)
        XCTAssertEqual(state.pipeline.queue.jobs.count, 1)
        XCTAssertEqual(state.pipeline.queue.jobs[0].mixPath?.lastPathComponent, "present.wav")
    }

    #if !APPSTORE
        func testBuildDebugRPCServerReturnsWiredServer() {
            let (state, _) = makeState()
            // Exercises buildDebugRPCServer's wiring, including the /v1 automation
            // closures (enqueueReturningIDs + jobStatus). Construction does not
            // start a listener, so boundPort is nil until start() is called.
            let server = state.buildDebugRPCServer()
            XCTAssertNil(server.boundPort)
        }

        /// Boots the `AppState`-wired server on an OS-assigned port and returns
        /// its base URL. Shared by the two socket tests below, which are separate
        /// only because one function cannot hold both under the length cap.
        /// `DebugRPCServerIntegrationTests.startServer` cannot stand in: it
        /// builds a bare `DebugRPCServer`, and driving the `AppState`-built one
        /// is the whole point here.
        private func startWiredServer(
            _ state: AppState, token: String,
        ) async throws -> (server: DebugRPCServer, baseURL: URL) {
            let server = state.buildDebugRPCServer(port: 0, token: token)
            server.start()
            addTeardownBlock { await server.stop() }
            for _ in 0 ..< 50 {
                if let p = server.boundPort, let url = URL(string: "http://127.0.0.1:\(p)") {
                    return (server, url)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw XCTestError(.timeoutWhileWaiting)
        }

        /// End-to-end over a real socket: every /v1 closure buildDebugRPCServer
        /// wires (enqueueReturningIDs, jobStatus, namingStatus, confirmNaming,
        /// skipJobNaming) is exercised through the actual AppState → pipeline path.
        func testBuildDebugRPCServerServesV1OverSocket() async throws {
            let (state, _) = makeState()
            let token = "appstate-rpc-e2e-token"
            let baseURL = try await startWiredServer(state, token: token).baseURL

            func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Int {
                var req = URLRequest(url: baseURL.appendingPathComponent(path))
                req.httpMethod = method
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.httpBody = body
                if let body { let (_, r) = try await URLSession.shared.upload(for: req, from: body); return code(r) }
                let (_, r) = try await URLSession.shared.data(for: req)
                return code(r)
            }
            func code(_ r: URLResponse) -> Int {
                (r as? HTTPURLResponse)?.statusCode ?? 0
            }

            // Enqueue a real file through the AppState pipeline (enqueueReturningIDs).
            let tmp = testLogDir.appendingPathComponent("e2e.wav")
            try Data("RIFF".utf8).write(to: tmp)
            var enqReq = URLRequest(url: baseURL.appendingPathComponent("v1/jobs"))
            enqReq.httpMethod = "POST"
            enqReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let enqBody = Data(#"{"paths":["\#(tmp.path)"]}"#.utf8)
            let (enqData, enqResp) = try await URLSession.shared.upload(for: enqReq, from: enqBody)
            XCTAssertEqual(code(enqResp), 200)
            struct EnqueueResult: Decodable { let jobIDs: [String] }
            let jobID = try XCTUnwrap(try JSONDecoder().decode(EnqueueResult.self, from: enqData).jobIDs.first)

            // jobStatus closure: the just-enqueued job is live → 200.
            let statusCode = try await send("GET", "v1/jobs/\(jobID)")
            XCTAssertEqual(statusCode, 200)

            // The job exists but isn't awaiting naming, so the AppState closures
            // run and: GET naming has nothing to return (404), while the
            // state-changing confirm/skip are a conflict on a live job (409).
            let naming = try await send("GET", "v1/jobs/\(jobID)/naming")
            XCTAssertEqual(naming, 404)
            let confirm = try await send("POST", "v1/jobs/\(jobID)/naming", body: Data(#"{"mapping":{}}"#.utf8))
            XCTAssertEqual(confirm, 409)
            let skip = try await send("POST", "v1/jobs/\(jobID)/naming/skip")
            XCTAssertEqual(skip, 409)

            // transcribe closure (blocking one-call): maxWaitSeconds 0 leaves the
            // just-enqueued job in-flight at the deadline → 202, exercising the
            // AppState closure's delegation to pipeline.transcribeAndWait.
            let txFile = testLogDir.appendingPathComponent("e2e-transcribe.wav")
            try Data("RIFF".utf8).write(to: txFile)
            let txBody = Data(#"{"path":"\#(txFile.path)","maxWaitSeconds":0}"#.utf8)
            let tx = try await send("POST", "v1/transcribe", body: txBody)
            XCTAssertEqual(tx, 202)

            // watch closures: the route tests stub these, and `DebugRPCServer.init`
            // declares defaults for both, so deleting the wiring arguments at the
            // `AppState` call site still compiles and leaves those tests green.
            // Driving the real closures over the socket is what pins them.
            let watchGet = try await send("GET", "v1/watch")
            XCTAssertEqual(watchGet, 200)
            let watchBad = try await send("POST", "v1/watch", body: Data(#"{"action":"nope"}"#.utf8))
            XCTAssertEqual(watchBad, 400, "an unknown verb must not reach the controller")

            // `stop` while not watching is a satisfied request, and reaching
            // `.unchanged` proves the control closure ran rather than a default.
            var stopReq = URLRequest(url: baseURL.appendingPathComponent("v1/watch"))
            stopReq.httpMethod = "POST"
            stopReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let stopBody = Data(#"{"action":"stop"}"#.utf8)
            let (stopData, stopResp) = try await URLSession.shared.upload(for: stopReq, from: stopBody)
            XCTAssertEqual(code(stopResp), 200)
            let dto = try JSONDecoder().decode(WatchStatusDTO.self, from: stopData)
            XCTAssertFalse(dto.watching)
            XCTAssertFalse(dto.manualRecording)
        }

        /// The `/v1/record` half of the same job, in its own test because the one
        /// above is at the function-length cap.
        ///
        /// One assertion, deliberately. `DebugRPCServer.init` defaults the record
        /// closures, so deleting the wiring arguments at the `AppState` call site
        /// would still compile and leave every route test green — and a `stop`
        /// with nothing recording is the one call that tells the two apart, since
        /// the real closure answers 200 (`unchanged`) where the default answers
        /// `.failed`, which the route renders as 503. A `GET` would pass against
        /// the default too, and the 400 is decided by `JSONDecoder` before any
        /// closure is reached.
        func testBuildDebugRPCServerServesV1RecordOverSocket() async throws {
            let (state, _) = makeState()
            // A verdict the default `.notRecording` projection cannot produce,
            // so the body distinguishes the wired status closure from it just as
            // the 200 distinguishes the wired control closure from `.failed`.
            state.permissions.handle(HealthCheckResult(screenRecording: .healthy, microphone: .denied))
            let token = "appstate-rpc-record-token"
            let baseURL = try await startWiredServer(state, token: token).baseURL

            var req = URLRequest(url: baseURL.appendingPathComponent("v1/record"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let body = Data(#"{"action":"stop"}"#.utf8)
            let (data, response) = try await URLSession.shared.upload(for: req, from: body)

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let dto = try JSONDecoder().decode(RecordStatusDTO.self, from: data)
            XCTAssertFalse(dto.microphoneHealthy, "the wired status closure, not the init default")
        }
    #endif

    func testEnqueueFilesAppPlusMicWithoutMixHasNilMixPath() {
        // No `_mix.wav` in selection — job carries nil mixPath; the pipeline
        // mixes app+mic into the workdir cache on the fly, no persistent mix
        // is written to recordings/.
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/20260311_143000_app.wav"),
            URL(fileURLWithPath: "/tmp/20260311_143000_mic.wav"),
        ]

        state.pipeline.enqueueFiles(urls)

        XCTAssertEqual(state.pipeline.queue.jobs.count, 1)
        let job = state.pipeline.queue.jobs[0]
        XCTAssertNil(job.mixPath, "paired without mix → nil mixPath")
        XCTAssertEqual(job.appPath?.lastPathComponent, "20260311_143000_app.wav")
        XCTAssertEqual(job.micPath?.lastPathComponent, "20260311_143000_mic.wav")
    }

    func testEnqueueFilesLoneAppFallsBackToSingleton() {
        let (state, _) = makeState()
        let urls = [URL(fileURLWithPath: "/tmp/orphan_app.wav")]

        state.pipeline.enqueueFiles(urls)

        XCTAssertEqual(state.pipeline.queue.jobs.count, 1)
        let job = state.pipeline.queue.jobs[0]
        XCTAssertEqual(job.mixPath?.lastPathComponent, "orphan_app.wav")
        XCTAssertNil(job.appPath)
        XCTAssertNil(job.micPath)
    }

    func testEnqueueFilesMixedPairAndSingleton() {
        let (state, _) = makeState()
        let urls = [
            URL(fileURLWithPath: "/tmp/meeting_app.wav"),
            URL(fileURLWithPath: "/tmp/meeting_mic.wav"),
            URL(fileURLWithPath: "/tmp/meeting_mix.wav"),
            URL(fileURLWithPath: "/tmp/podcast.mp3"),
        ]

        state.pipeline.enqueueFiles(urls)

        XCTAssertEqual(state.pipeline.queue.jobs.count, 2)
        let paired = state.pipeline.queue.jobs.first { $0.appPath != nil }
        let single = state.pipeline.queue.jobs.first { $0.appPath == nil }
        XCTAssertEqual(paired?.meetingTitle, "meeting")
        XCTAssertEqual(single?.meetingTitle, "podcast")
    }

    func testEnqueueFilesUsesSidecarMetadataWhenPresent() throws {
        let (state, _) = makeState()
        let tmpDir = try makeTempDirectory(prefix: "enqueue-sidecar")
        let basename = "20260311_143000"

        try RecordingSidecar(
            title: "Sprint Review",
            appName: "Microsoft Teams",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_777_001_800),
            participants: ["Speaker A", "Speaker B"],
            micDelaySeconds: 0.25,
            trigger: .auto,
            mixFilename: "\(basename)_mix.wav",
            appFilename: "\(basename)_app.wav",
            micFilename: "\(basename)_mic.wav",
        ).write(toDirectory: tmpDir, basename: basename)

        state.pipeline.enqueueFiles([
            tmpDir.appendingPathComponent("\(basename)_app.wav"),
            tmpDir.appendingPathComponent("\(basename)_mic.wav"),
            tmpDir.appendingPathComponent("\(basename)_mix.wav"),
        ])

        XCTAssertEqual(state.pipeline.queue.jobs.count, 1)
        let job = state.pipeline.queue.jobs[0]
        XCTAssertEqual(job.meetingTitle, "Sprint Review")
        XCTAssertEqual(job.appName, "Microsoft Teams")
        XCTAssertEqual(job.participants, ["Speaker A", "Speaker B"])
        XCTAssertEqual(job.micDelay, 0.25, accuracy: 0.0001)
    }

    // MARK: - pipeline.ensureQueue

    func testEnsureQueueReplacesBareQueue() {
        // Bare queue (no engine) — uses the no-engine init; logDir is the
        // production path but this test never enqueues so no I/O hits it.
        let notifier = RecordingNotifier()
        let state = AppState(notifier: notifier)
        state.pipeline.queue = PipelineQueue(logDir: testLogDir)
        XCTAssertNil(state.pipeline.queue.engine, "Precondition: fresh queue has no engine")

        state.pipeline.ensureQueue()

        XCTAssertNotNil(state.pipeline.queue.engine)
    }

    func testEnsureQueueIdempotent() {
        let (state, _) = makeState()
        state.pipeline.ensureQueue()
        let firstID = ObjectIdentifier(state.pipeline.queue)

        state.pipeline.ensureQueue()

        XCTAssertEqual(ObjectIdentifier(state.pipeline.queue), firstID)
    }

    // MARK: - pipeline.makeQueue

    func testMakeQueueHasEngine() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.pipeline.makeQueue().engine)
    }

    func testMakeQueueHasDiarizationFactory() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.pipeline.makeQueue().diarizationFactory)
    }

    func testMakeQueueHasProtocolGeneratorFactory() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.pipeline.makeQueue().protocolGeneratorFactory)
    }

    func testMakeQueueSetsOutputDir() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.pipeline.makeQueue().outputDir)
    }

    // MARK: - makeProtocolGenerator

    func testMakeProtocolGeneratorOpenAI() {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let state = AppState(settings: settings)
        XCTAssertTrue(state.pipeline.makeProtocolGenerator() is OpenAIProtocolGenerator)
    }

    #if !APPSTORE
        func testMakeProtocolGeneratorClaudeCLI() {
            let settings = AppSettings()
            settings.protocolProvider = .claudeCLI
            let state = AppState(settings: settings)
            XCTAssertTrue(state.pipeline.makeProtocolGenerator() is ClaudeCLIProtocolGenerator)
        }
    #endif

    func testMakeProtocolGeneratorReturnsNilForNoneProvider() {
        let settings = AppSettings()
        settings.protocolProvider = .none
        let state = AppState(settings: settings)
        XCTAssertNil(state.pipeline.makeProtocolGenerator())
    }

    // MARK: - pipeline.configureCallbacks

    func testConfigureCallbacksDoneFiresNotification() throws {
        let tmpDir = try makeTempDirectory(prefix: "appstate_callbacks")

        let (state, notifier) = makeIsolatedState(logDir: tmpDir)
        state.pipeline.configureCallbacks()

        var job = makeJob(title: "Sprint Review")
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        state.pipeline.queue.onJobStateChange?(job, .transcribing, .done)

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Protocol Ready")
        XCTAssertEqual(notifier.calls[0].body, "Sprint Review")
    }

    func testConfigureCallbacksErrorFiresNotification() throws {
        let tmpDir = try makeTempDirectory(prefix: "appstate_callbacks")

        let (state, notifier) = makeIsolatedState(logDir: tmpDir)
        state.pipeline.configureCallbacks()

        var job = makeJob()
        job = PipelineJob(
            meetingTitle: job.meetingTitle,
            appName: job.appName,
            mixPath: job.mixPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        // Simulate a job with an error string
        let errorJob = jobWithError(job, message: "Transcription failed")
        state.pipeline.queue.onJobStateChange?(errorJob, .transcribing, .error)

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "Error")
        XCTAssertEqual(notifier.calls[0].body, "Transcription failed")
    }

    func testConfigureCallbacksTranscribingNoNotification() throws {
        let tmpDir = try makeTempDirectory(prefix: "appstate_callbacks")

        let (state, notifier) = makeIsolatedState(logDir: tmpDir)
        state.pipeline.configureCallbacks()

        state.pipeline.queue.onJobStateChange?(makeJob(), .waiting, .transcribing)

        XCTAssertTrue(notifier.calls.isEmpty)
    }

    // MARK: - Engine Switching

    func testActiveTranscriptionEngineDefaultsToWhisperKit() {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let state = AppState(settings: settings)
        XCTAssertTrue(state.engines.activeTranscriptionEngine is WhisperKitEngine)
    }

    func testActiveTranscriptionEngineReturnsParakeetWhenSet() {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)
        XCTAssertTrue(state.engines.activeTranscriptionEngine is ParakeetEngine)
    }

    func testActiveTranscriptionEngineSwitchesBack() {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)
        XCTAssertTrue(state.engines.activeTranscriptionEngine is ParakeetEngine)

        settings.transcriptionEngine = .whisperKit
        XCTAssertTrue(state.engines.activeTranscriptionEngine is WhisperKitEngine)
    }

    func testMakeQueueUsesActiveEngine() {
        let (state, _) = makeState()
        XCTAssertNotNil(state.pipeline.makeQueue().engine, "WhisperKit engine should be set")

        state.settings.transcriptionEngine = .parakeet
        XCTAssertNotNil(state.pipeline.makeQueue().engine, "Parakeet engine should be set")
    }

    func testEnsureQueueWithParakeet() {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)

        state.pipeline.ensureQueue()

        XCTAssertNotNil(state.pipeline.queue.engine)
    }

    // MARK: - makeQueue settings

    func testMakeQueueUsesDiarizeSettingFromSettings() {
        let (state, _) = makeState()
        state.settings.diarize = true
        let queue = state.pipeline.makeQueue()
        XCTAssertTrue(queue.diarizeEnabled)
    }

    func testMakeQueueUsesMicLabelFromSettings() {
        let (state, _) = makeState()
        state.settings.micName = "Speaker A"
        let queue = state.pipeline.makeQueue()
        XCTAssertEqual(queue.micLabel, "Speaker A")
    }

    func testMakeQueueUsesNumSpeakersFromSettings() {
        let (state, _) = makeState()
        state.settings.numSpeakers = 4
        let queue = state.pipeline.makeQueue()
        XCTAssertEqual(queue.numSpeakers, 4)
    }
}

// MARK: - Private helpers

/// Returns a copy of `job` with the error field set via updateJobState simulation.
/// Since PipelineJob is a struct and error is set by PipelineQueue internally,
/// we construct a new job and set the error via the queue's updateJobState.
@MainActor
private func jobWithError(_ job: PipelineJob, message: String) -> PipelineJob {
    // PipelineJob.error is var but directly settable since it's internal
    var copy = job
    copy.error = message
    return copy
}
