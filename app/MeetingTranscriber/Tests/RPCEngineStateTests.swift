#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Verifies that `rpcStateSnapshot()` exposes the live engine state so
    /// `mt-cli state` and similar tools can observe runtime engine-setting
    /// propagation without spawning a transcription.
    @MainActor
    final class RPCEngineStateTests: XCTestCase {
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var defaults: UserDefaults!
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var settings: AppSettings!
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var testSuiteName: String!

        override func setUp() async throws {
            try await super.setUp()
            testSuiteName = "RPCEngineStateTests-\(getpid())-\(UUID().uuidString)"
            guard let suite = UserDefaults(suiteName: testSuiteName) else {
                XCTFail("Could not create test UserDefaults suite")
                return
            }
            defaults = suite
            settings = AppSettings(defaults: defaults)
        }

        override func tearDown() async throws {
            settings = nil
            defaults.removePersistentDomain(forName: testSuiteName)
            defaults = nil
            testSuiteName = nil
            try await super.tearDown()
        }

        // MARK: - Snapshot reflects engine state

        // Tests set engine properties directly so they're decoupled from the
        // settings → engine propagation logic (which has its own coverage).
        // What's verified here: the snapshot mirrors whatever the live engines
        // currently expose.

        func test_snapshot_reflectsActiveEngine_whisperKit() {
            settings.transcriptionEngine = .whisperKit
            let state = AppState(settings: settings)
            state.engines.whisperKit.modelVariant = "openai_whisper-large-v3-v20240930_turbo"
            state.engines.whisperKit.language = "de"

            let snapshot = state.rpcStateSnapshot()

            XCTAssertEqual(snapshot.engines.active, .whisperKit)
            XCTAssertEqual(snapshot.engines.whisperKit.language, "de")
            XCTAssertEqual(
                snapshot.engines.whisperKit.modelVariant,
                "openai_whisper-large-v3-v20240930_turbo",
            )
        }

        func test_snapshot_reflectsActiveEngine_parakeet() {
            settings.transcriptionEngine = .parakeet
            let state = AppState(settings: settings)
            state.engines.parakeetEngine.customVocabularyPath = "/tmp/parakeet-vocab.txt"

            let snapshot = state.rpcStateSnapshot()

            XCTAssertEqual(snapshot.engines.active, .parakeet)
            XCTAssertEqual(
                snapshot.engines.parakeet.customVocabularyPath, "/tmp/parakeet-vocab.txt",
            )
        }

        func test_snapshot_exposesEngineModelStates() {
            let state = AppState(settings: settings)

            let snapshot = state.rpcStateSnapshot()

            // Freshly constructed engines have loaded nothing. The field
            // exists so driver scripts (e2e-cpu-load.sh) can wait for
            // "loaded" before measuring an idle window — pipeline state
            // tracks jobs, not model preloads.
            XCTAssertEqual(snapshot.engines.whisperKit.modelState, "unloaded")
            XCTAssertEqual(snapshot.engines.parakeet.modelState, "unloaded")
        }

        func test_modelStateWireFormat_pinsDescriptionContract() {
            // e2e-cpu-load.sh string-matches `.modelState == "loaded"` to know
            // when model preload is done. The wire value is
            // `String(describing: EngineModelState).lowercased()` — pin that mapping
            // here so a WhisperKit upgrade changing the enum's description
            // breaks THIS test, not silently the e2e runner's settle gate.
            XCTAssertEqual(String(describing: EngineModelState.loaded).lowercased(), "loaded")
            XCTAssertEqual(String(describing: EngineModelState.unloaded).lowercased(), "unloaded")
        }

        func test_snapshot_whisperLanguageNil_surfacesAsNil() {
            let state = AppState(settings: settings)
            state.engines.whisperKit.language = nil

            let snapshot = state.rpcStateSnapshot()

            // `nil` = auto-detect on `DecodingOptions`; surface that here too
            // so JSON consumers see `null`, not the empty-string sentinel.
            XCTAssertNil(snapshot.engines.whisperKit.language)
        }

        // MARK: - Live propagation through the snapshot

        /// End-to-end smoketest: the snapshot is the supported way to observe
        /// runtime settings → engine propagation from outside the process.
        /// Same flow `mt-cli state | jq .engines` exercises against the live app.
        func test_snapshot_reflectsRuntimeSettingChange() async {
            settings.transcriptionEngine = .parakeet
            let state = AppState(settings: settings)

            XCTAssertEqual(
                state.rpcStateSnapshot().engines.parakeet.customVocabularyPath, "",
            )

            settings.customVocabularyPath = "/tmp/runtime.txt"
            await waitFor(
                state.rpcStateSnapshot().engines.parakeet.customVocabularyPath
                    == "/tmp/runtime.txt",
            )

            XCTAssertEqual(
                state.rpcStateSnapshot().engines.parakeet.customVocabularyPath,
                "/tmp/runtime.txt",
            )
        }

        // MARK: - Watch state

        func test_snapshot_exposesWatchState() {
            let state = AppState(settings: settings)
            // No watch loop yet → nil (encodes as absent in JSON).
            XCTAssertNil(state.rpcStateSnapshot().watchState)

            // Live wiring: the snapshot mirrors the loop's state, so driver
            // scripts (e2e-cpu-load.sh) can gate a measurement window on
            // `.watchState == "recording"` without a caption signal.
            let (loop, _) = makeTestWatchLoop()
            state.watching.watchLoop = loop
            loop.start()
            defer { loop.stop() }
            XCTAssertEqual(state.rpcStateSnapshot().watchState, "watching")
        }

        // MARK: - JSON shape

        func test_snapshot_jsonContainsEnginesBlock() throws {
            settings.transcriptionEngine = .whisperKit
            let state = AppState(settings: settings)

            let json = try state.rpcStateSnapshot().jsonData()
            let s = try XCTUnwrap(String(data: json, encoding: .utf8))

            XCTAssertTrue(s.contains("\"engines\""))
            XCTAssertTrue(s.contains("\"active\""))
            XCTAssertTrue(s.contains("\"whisperKit\""))
            XCTAssertTrue(s.contains("\"parakeet\""))
        }

        // MARK: - LastJob

        func test_snapshot_lastJob_isNilWhenQueueEmpty() {
            let state = AppState(settings: settings)
            XCTAssertNil(state.rpcStateSnapshot().lastJob)
        }

        func test_snapshot_lastJob_skipsWaitingAndInFlightJobs() {
            let state = AppState(settings: settings)
            let waiting = makeJob(title: "in-flight")
            state.pipeline.queue.insertJobForTesting(waiting)
            // .waiting is the default state on init; not finished yet.
            XCTAssertNil(state.rpcStateSnapshot().lastJob)
        }

        func test_snapshot_lastJob_returnsMostRecentFinishedJob() throws {
            let state = AppState(settings: settings)
            var done = makeJob(title: "earlier-done")
            done.state = .done
            done.transcriptPath = URL(fileURLWithPath: "/tmp/transcript-earlier.md")
            var errored = makeJob(title: "later-error")
            errored.state = .error
            errored.error = "Empty transcript"
            errored.warnings = ["mic silent"]
            // Order in the array determines "last" — `last(where:)` walks
            // back-to-front. Append done first, then errored, so the latter
            // is returned.
            state.pipeline.queue.insertJobForTesting(done)
            state.pipeline.queue.insertJobForTesting(errored)

            let snapshot = state.rpcStateSnapshot()
            let last = try XCTUnwrap(snapshot.lastJob)
            XCTAssertEqual(last.meetingTitle, "later-error")
            XCTAssertEqual(last.state, .error)
            XCTAssertEqual(last.error, "Empty transcript")
            XCTAssertEqual(last.warnings, ["mic silent"])
            XCTAssertNil(last.transcriptPath)
            XCTAssertGreaterThanOrEqual(last.durationSec, 0)
        }

        func test_snapshot_lastJob_jsonRoundtripsAllFields() throws {
            let state = AppState(settings: settings)
            var done = makeJob(title: "Acme · Standup", participants: ["Alice", "Bob"])
            done.state = .done
            done.transcriptPath = URL(fileURLWithPath: "/tmp/transcript.md")
            done.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
            done.warnings = ["diarization fell back to single track"]
            state.pipeline.queue.insertJobForTesting(done)

            let json = try state.rpcStateSnapshot().jsonData()
            let decoded = try JSONDecoder().decode(RPCStateSnapshot.self, from: json)
            let last = try XCTUnwrap(decoded.lastJob)

            XCTAssertEqual(last.meetingTitle, "Acme · Standup")
            XCTAssertEqual(last.state, .done)
            XCTAssertEqual(last.transcriptPath, "/tmp/transcript.md")
            XCTAssertEqual(last.protocolPath, "/tmp/protocol.md")
            XCTAssertEqual(last.participants, ["Alice", "Bob"])
            XCTAssertEqual(last.warnings, ["diarization fell back to single track"])
        }

        // MARK: - Helpers

        private func makeJob(title: String, participants: [String] = []) -> PipelineJob {
            PipelineJob(
                meetingTitle: title,
                appName: "MeetingSimulator",
                mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
                appPath: nil,
                micPath: nil,
                micDelay: 0,
                participants: participants,
            )
        }
    }
#endif
