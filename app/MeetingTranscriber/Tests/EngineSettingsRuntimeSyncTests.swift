@testable import MeetingTranscriber
import XCTest

/// Verifies that `AppSettings` changes propagate to the engine instances at
/// runtime, not just on app restart. The settings ↔ engine sync used to run
/// only once when the pipeline queue was first built; later UI changes
/// silently dropped on the floor until the next launch.
///
/// Exercises `EngineController` directly — the concern was extracted out of
/// `AppState`, so these tests now construct the bare controller (no full
/// `AppState`, no log-streamer subprocess) and assert on its engine instances.
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

    // MARK: - Initial sync at EngineController init

    func test_initialSync_propagatesWhisperLanguageToEngine() {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.language, "de")
    }

    func test_initialSync_propagatesCustomVocabularyPathToParakeet() {
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyPath = "/tmp/init-vocab.txt"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/init-vocab.txt")
    }

    func test_initialSync_propagatesWhisperKitModelToEngine() {
        settings.transcriptionEngine = .whisperKit
        settings.whisperKitModel = "openai_whisper-small"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.modelVariant, "openai_whisper-small")
    }

    // MARK: - Runtime propagation

    func test_runtimeChange_whisperLanguage_propagatesToEngine() async {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.language, "de")

        settings.whisperLanguage = "en"

        await waitFor(engines.whisperKit.language == "en")
        XCTAssertEqual(engines.whisperKit.language, "en")
    }

    /// The model variant was the one engine-config key missing from the
    /// reactive observer: changing it in Settings only reached the engine via
    /// the explicit "Load Model" button or a relaunch, so a user who picked a
    /// new model and started a meeting silently transcribed with the old one.
    func test_runtimeChange_whisperKitModel_propagatesToEngine() async {
        settings.transcriptionEngine = .whisperKit
        let engines = EngineController(settings: settings)
        let original = engines.whisperKit.modelVariant

        settings.whisperKitModel = "openai_whisper-small"

        await waitFor(engines.whisperKit.modelVariant == "openai_whisper-small")
        XCTAssertEqual(engines.whisperKit.modelVariant, "openai_whisper-small")
        XCTAssertNotEqual(engines.whisperKit.modelVariant, original)
    }

    func test_runtimeChange_customVocabularyPath_propagatesToParakeet() async {
        settings.transcriptionEngine = .parakeet
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "")

        settings.customVocabularyPath = "/tmp/runtime-vocab.txt"

        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/runtime-vocab.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/runtime-vocab.txt")
    }

    // MARK: - Re-arming

    /// `withObservationTracking` is one-shot per registration; the re-arm in
    /// `onChange` is what makes consecutive changes fire. Without it, only
    /// the first change would propagate and subsequent ones silently no-op.
    func test_observation_rearmsForMultipleChanges() async {
        settings.transcriptionEngine = .parakeet
        let engines = EngineController(settings: settings)

        settings.customVocabularyPath = "/tmp/v1.txt"
        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/v1.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/v1.txt")

        settings.customVocabularyPath = "/tmp/v2.txt"
        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/v2.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/v2.txt")

        settings.customVocabularyPath = "/tmp/v3.txt"
        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/v3.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/v3.txt")
    }

    // MARK: - Engine switch

    /// Switching `transcriptionEngine` must re-sync the now-active engine
    /// with the existing settings — otherwise the user gets a stale engine
    /// state until they touch any other setting.
    func test_engineSwitch_syncsNewlyActiveEngine() async {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        settings.customVocabularyPath = "/tmp/parakeet-vocab.txt"
        let engines = EngineController(settings: settings)

        XCTAssertEqual(engines.whisperKit.language, "de")
        XCTAssertEqual(
            engines.parakeetEngine.customVocabularyPath, "",
            "Parakeet inactive at init — no sync expected",
        )

        settings.transcriptionEngine = .parakeet

        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/parakeet-vocab.txt")
        XCTAssertEqual(
            engines.parakeetEngine.customVocabularyPath, "/tmp/parakeet-vocab.txt",
        )
    }
}
