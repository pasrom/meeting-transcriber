#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Direct coverage for `AppState.makeSpeakerDBActions()` closures.
    ///
    /// `DebugRPCServerTests` covers the HTTP routing layer with a stub
    /// `SpeakerDBActions`; the real factory's `rename`/`delete`/`merge`/`seed`
    /// closures stay uncovered there. These tests invoke the closures
    /// against a temp-path `SpeakerMatcher` so we exercise:
    ///
    ///   - the outcome-mapping switch in `rename` (renamed / merged / noop / notFound)
    ///   - the conditional refresh in `delete` / `merge` (only on success)
    ///   - the random-embedding seed path and its `isSynthetic = true` flag
    ///
    /// The factory injection (`speakerMatcherFactory:` parameter) is the only
    /// production hook; default arg preserves the prod call site at
    /// `AppState.swift:186` byte-for-byte.
    @MainActor
    final class AppStateRPCActionsTests: XCTestCase {
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var tmpDir: URL!
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var dbPath: URL!
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var state: AppState!
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var actions: SpeakerDBActions!

        override func setUp() async throws {
            try await super.setUp()
            tmpDir = try makeTempDirectory(prefix: "AppStateRPCActions")
            dbPath = tmpDir.appendingPathComponent("speakers.json")
            let suite = "AppStateRPCActionsTests-\(getpid())-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                XCTFail("Could not create test UserDefaults suite")
                return
            }
            let settings = AppSettings(defaults: defaults)
            state = AppState(settings: settings)
            actions = state.makeSpeakerDBActions { [dbPath] in
                SpeakerMatcher(dbPath: dbPath)
            }
        }

        override func tearDown() async throws {
            // `LiveCaptionsState.applyPartial`/`applyFinalized` schedule a
            // 5 s auto-clear Task via `scheduleAutoClear()`. Cancelling
            // here keeps a long-running test suite from accumulating
            // pending Tasks that outlive their AppState.
            state?.liveCaptions.clear()
            actions = nil
            state = nil
            tmpDir = nil
            dbPath = nil
            try await super.tearDown()
        }

        // MARK: - rename

        func test_rename_renamedOutcome_persistsNewName() {
            seedSpeaker(name: "Old")

            let outcome = actions.rename("Old", "New")

            XCTAssertEqual(outcome, .ok)
            let names = SpeakerMatcher(dbPath: dbPath).loadDB().map(\.name)
            XCTAssertEqual(names, ["New"])
        }

        func test_rename_mergedOutcome_collapsesIntoTarget() {
            seedSpeaker(name: "Alpha")
            seedSpeaker(name: "Beta")

            let outcome = actions.rename("Alpha", "Beta")

            XCTAssertEqual(outcome, .merged)
            XCTAssertEqual(SpeakerMatcher(dbPath: dbPath).loadDB().count, 1)
        }

        func test_rename_sameSourceAndTarget_isNoop() {
            seedSpeaker(name: "X")

            let outcome = actions.rename("X", "X")

            XCTAssertEqual(outcome, .noop)
        }

        func test_rename_missingSource_isNotFound() {
            let outcome = actions.rename("DoesNotExist", "Whatever")

            XCTAssertEqual(outcome, .notFound)
        }

        // MARK: - delete

        func test_delete_existingSpeaker_returnsOK() {
            seedSpeaker(name: "Doomed")

            let outcome = actions.delete("Doomed")

            XCTAssertEqual(outcome, .ok)
            XCTAssertTrue(SpeakerMatcher(dbPath: dbPath).loadDB().isEmpty)
        }

        func test_delete_missingSpeaker_isNotFound() {
            let outcome = actions.delete("Phantom")

            XCTAssertEqual(outcome, .notFound)
        }

        // MARK: - merge

        func test_merge_existingPair_returnsOK() {
            seedSpeaker(name: "A")
            seedSpeaker(name: "B")

            let outcome = actions.merge("A", "B")

            XCTAssertEqual(outcome, .ok)
            let names = SpeakerMatcher(dbPath: dbPath).loadDB().map(\.name)
            XCTAssertEqual(names, ["B"])
        }

        func test_merge_missingSource_isNotFound() {
            seedSpeaker(name: "Only")

            let outcome = actions.merge("Missing", "Only")

            XCTAssertEqual(outcome, .notFound)
        }

        // MARK: - seed

        /// `isSynthetic = true` is a hard invariant: the seed closure inserts
        /// a uniformly-random embedding, so the entry must never be eligible
        /// for auto-naming a real speaker. `SpeakerMatcher.matchVerbose`
        /// filters synthetic entries out — losing this flag would silently
        /// poison the matcher with noise.
        func test_seed_addsSyntheticEntry() {
            let outcome = actions.seed("SeededName")

            XCTAssertEqual(outcome, .ok)
            let entries = SpeakerMatcher(dbPath: dbPath).loadDB()
            XCTAssertEqual(entries.count, 1)
            let entry = entries[0]
            XCTAssertEqual(entry.name, "SeededName")
            XCTAssertTrue(entry.isSynthetic, "Seed must mark entries synthetic")
            XCTAssertEqual(entry.embeddings.count, 1)
            XCTAssertEqual(entry.embeddings[0].count, AppState.seedEmbeddingDimension)
            XCTAssertEqual(entry.centroid?.count, AppState.seedEmbeddingDimension)
        }

        // MARK: - pendingNamingJobs mapping in rpcStateSnapshot

        /// Drives the `pendingSpeakerNamingJobs.map` closure in
        /// `rpcStateSnapshot()` — previously uncovered because no test had
        /// set up the `.speakerNamingPending` queue state. The closure maps
        /// queue state + per-job speaker-naming data into RPC snapshot rows;
        /// `mt-cli state` and the headless E2E driver rely on its fields.
        func test_snapshot_pendingNamingJobs_mapsQueueStateToRPCFields() throws {
            var job = makeJob(title: "Acme Standup")
            job.state = .speakerNamingPending
            state.pipelineQueue.insertJobForTesting(job)
            state.pipelineQueue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
                jobID: job.id,
                meetingTitle: "Acme Standup",
                mapping: ["R_0": "Alice", "R_1": "Bob"],
                speakingTimes: [:],
                embeddings: [:],
                audioPath: nil,
                segments: [],
                participants: [],
                isDualSource: false,
            )

            let snapshot = state.rpcStateSnapshot()

            XCTAssertEqual(snapshot.pendingNamingJobs.count, 1)
            let pending = try XCTUnwrap(snapshot.pendingNamingJobs.first)
            XCTAssertEqual(pending.jobID, job.id.uuidString)
            XCTAssertEqual(pending.meetingTitle, "Acme Standup")
            XCTAssertEqual(pending.speakerCount, 2)
            XCTAssertEqual(snapshot.pipeline.pendingNamingJobCount, 1)
        }

        /// Covers the `data?.mapping.count ?? 0` fallback branch when a job
        /// is in `.speakerNamingPending` but no per-job data has been wired
        /// up yet (transient state between diarization completion and the
        /// data getting stashed).
        func test_snapshot_pendingNamingJob_withoutData_speakerCountIsZero() throws {
            var job = makeJob(title: "Orphan")
            job.state = .speakerNamingPending
            state.pipelineQueue.insertJobForTesting(job)

            let snapshot = state.rpcStateSnapshot()

            let pending = try XCTUnwrap(snapshot.pendingNamingJobs.first)
            XCTAssertEqual(pending.speakerCount, 0)
        }

        // MARK: - liveCaptions mapping in rpcStateSnapshot

        /// Empty LiveCaptionsState should serialise to empty strings + empty
        /// finals — what an idle / non-recording app should expose.
        func test_snapshot_liveCaptions_empty_whenStateIsClear() {
            let snapshot = state.rpcStateSnapshot()
            XCTAssertEqual(snapshot.liveCaptions.hypothesisMic, "")
            XCTAssertEqual(snapshot.liveCaptions.hypothesisApp, "")
            XCTAssertTrue(snapshot.liveCaptions.recentFinals.isEmpty)
        }

        /// Per-channel hypothesis + finals must round-trip into the
        /// snapshot, with the channel enum flattened to the short string
        /// the e2e driver reads via jq.
        func test_snapshot_liveCaptions_mapsHypothesisAndFinalsPerChannel() {
            state.liveCaptions.applyPartial("hello", channel: .mic)
            state.liveCaptions.applyPartial("guten tag", channel: .app)
            state.liveCaptions.applyFinalized("hello there", channel: .mic)
            state.liveCaptions.applyFinalized("guten morgen", channel: .app)

            let snapshot = state.rpcStateSnapshot()

            // applyFinalized clears the per-channel hypothesis, so both
            // hypothesis fields are empty in this scenario.
            XCTAssertEqual(snapshot.liveCaptions.hypothesisMic, "")
            XCTAssertEqual(snapshot.liveCaptions.hypothesisApp, "")
            XCTAssertEqual(snapshot.liveCaptions.recentFinals.count, 2)
            XCTAssertEqual(snapshot.liveCaptions.recentFinals[0].channel, .mic)
            XCTAssertEqual(snapshot.liveCaptions.recentFinals[0].text, "hello there")
            XCTAssertEqual(snapshot.liveCaptions.recentFinals[1].channel, .app)
            XCTAssertEqual(snapshot.liveCaptions.recentFinals[1].text, "guten morgen")
        }

        // MARK: - Helpers

        private func makeJob(title: String) -> PipelineJob {
            PipelineJob(
                meetingTitle: title,
                appName: "MeetingSimulator",
                mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
                appPath: nil,
                micPath: nil,
                micDelay: 0,
                participants: [],
            )
        }

        private func seedSpeaker(name: String) {
            let dim = AppState.seedEmbeddingDimension
            SpeakerMatcher(dbPath: dbPath).mutateDB { stored in
                stored.append(StoredSpeaker(
                    name: name,
                    embeddings: [[Float](repeating: 0, count: dim)],
                    centroid: [Float](repeating: 0, count: dim),
                    centroidSampleCount: 1,
                ))
            }
        }
    }
#endif
