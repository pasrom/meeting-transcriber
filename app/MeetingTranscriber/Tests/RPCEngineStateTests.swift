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
            state.whisperKit.modelVariant = "openai_whisper-large-v3-v20240930_turbo"
            state.whisperKit.language = "de"

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
            state.parakeetEngine.customVocabularyPath = "/tmp/parakeet-vocab.txt"

            let snapshot = state.rpcStateSnapshot()

            XCTAssertEqual(snapshot.engines.active, .parakeet)
            XCTAssertEqual(
                snapshot.engines.parakeet.customVocabularyPath, "/tmp/parakeet-vocab.txt",
            )
        }

        func test_snapshot_reflectsActiveEngine_qwen3() throws {
            guard #available(macOS 15, *) else {
                throw XCTSkip("Qwen3 requires macOS 15+")
            }
            settings.transcriptionEngine = .qwen3
            let state = AppState(settings: settings)
            state.qwen3Engine.language = "en"

            let snapshot = state.rpcStateSnapshot()

            XCTAssertEqual(snapshot.engines.active, .qwen3)
            XCTAssertEqual(snapshot.engines.qwen3?.language, "en")
        }

        func test_snapshot_whisperLanguageNil_surfacesAsNil() {
            let state = AppState(settings: settings)
            state.whisperKit.language = nil

            let snapshot = state.rpcStateSnapshot()

            // `nil` = auto-detect on `DecodingOptions`; surface that here too
            // so JSON consumers see `null`, not the empty-string sentinel.
            XCTAssertNil(snapshot.engines.whisperKit.language)
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
    }
#endif
