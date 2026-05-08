@testable import MeetingTranscriber
import XCTest

/// Verifies that `AppSettings` changes propagate to the engine instances at
/// runtime, not just on app restart. The settings ↔ engine sync used to run
/// only once when the pipeline queue was first built; later UI changes
/// silently dropped on the floor until the next launch.
@MainActor
final class EngineSettingsRuntimeSyncTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "EngineSettingsRuntimeSyncTests-\(getpid())-\(UUID().uuidString)"
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

    // MARK: - Initial sync at AppState init

    func test_initialSync_propagatesWhisperLanguageToEngine() {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        let state = AppState(settings: settings)
        XCTAssertEqual(state.whisperKit.language, "de")
    }

    func test_initialSync_propagatesCustomVocabularyPathToParakeet() {
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyPath = "/tmp/init-vocab.txt"
        let state = AppState(settings: settings)
        XCTAssertEqual(state.parakeetEngine.customVocabularyPath, "/tmp/init-vocab.txt")
    }

    // MARK: - Runtime propagation

    func test_runtimeChange_whisperLanguage_propagatesToEngine() async {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        let state = AppState(settings: settings)
        XCTAssertEqual(state.whisperKit.language, "de")

        settings.whisperLanguage = "en"

        await waitFor(state.whisperKit.language == "en")
        XCTAssertEqual(state.whisperKit.language, "en")
    }

    func test_runtimeChange_customVocabularyPath_propagatesToParakeet() async {
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)
        XCTAssertEqual(state.parakeetEngine.customVocabularyPath, "")

        settings.customVocabularyPath = "/tmp/runtime-vocab.txt"

        await waitFor(state.parakeetEngine.customVocabularyPath == "/tmp/runtime-vocab.txt")
        XCTAssertEqual(state.parakeetEngine.customVocabularyPath, "/tmp/runtime-vocab.txt")
    }

    func test_runtimeChange_qwen3Language_propagatesToEngine() async throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("Qwen3 requires macOS 15+")
        }
        settings.transcriptionEngine = .qwen3
        settings.qwen3Language = "de"
        let state = AppState(settings: settings)
        XCTAssertEqual(state.qwen3Engine.language, "de")

        settings.qwen3Language = "en"

        await waitFor(state.qwen3Engine.language == "en")
        XCTAssertEqual(state.qwen3Engine.language, "en")
    }

    // MARK: - Re-arming

    /// `withObservationTracking` is one-shot per registration; the re-arm in
    /// `onChange` is what makes consecutive changes fire. Without it, only
    /// the first change would propagate and subsequent ones silently no-op.
    func test_observation_rearmsForMultipleChanges() async {
        settings.transcriptionEngine = .parakeet
        let state = AppState(settings: settings)

        settings.customVocabularyPath = "/tmp/v1.txt"
        await waitFor(state.parakeetEngine.customVocabularyPath == "/tmp/v1.txt")
        XCTAssertEqual(state.parakeetEngine.customVocabularyPath, "/tmp/v1.txt")

        settings.customVocabularyPath = "/tmp/v2.txt"
        await waitFor(state.parakeetEngine.customVocabularyPath == "/tmp/v2.txt")
        XCTAssertEqual(state.parakeetEngine.customVocabularyPath, "/tmp/v2.txt")

        settings.customVocabularyPath = "/tmp/v3.txt"
        await waitFor(state.parakeetEngine.customVocabularyPath == "/tmp/v3.txt")
        XCTAssertEqual(state.parakeetEngine.customVocabularyPath, "/tmp/v3.txt")
    }

    // MARK: - Engine switch

    /// Switching `transcriptionEngine` must re-sync the now-active engine
    /// with the existing settings — otherwise the user gets a stale engine
    /// state until they touch any other setting.
    func test_engineSwitch_syncsNewlyActiveEngine() async {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        settings.customVocabularyPath = "/tmp/parakeet-vocab.txt"
        let state = AppState(settings: settings)

        XCTAssertEqual(state.whisperKit.language, "de")
        XCTAssertEqual(
            state.parakeetEngine.customVocabularyPath, "",
            "Parakeet inactive at init — no sync expected",
        )

        settings.transcriptionEngine = .parakeet

        await waitFor(state.parakeetEngine.customVocabularyPath == "/tmp/parakeet-vocab.txt")
        XCTAssertEqual(
            state.parakeetEngine.customVocabularyPath, "/tmp/parakeet-vocab.txt",
        )
    }
}
