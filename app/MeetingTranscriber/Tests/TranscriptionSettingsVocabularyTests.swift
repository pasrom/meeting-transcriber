@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class TranscriptionSettingsVocabularyTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsVocabularyTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testVocabularyPathFieldWritesBackThroughTheBookmarkSafeSetter() throws {
        let settings = AppSettings(defaults: defaults)
        let field = try makeView(settings: settings).inspect().find(ViewType.TextField.self) { field in
            try field.accessibilityIdentifier() == A11yID.customVocabularyPathField
        }

        try field.setInput("/tmp/meeting-terms.txt")

        XCTAssertEqual(settings.customVocabularyPath, "/tmp/meeting-terms.txt")
        XCTAssertNil(settings.customVocabularyBookmark)
    }

    func testTerminologyEditorHasStableAccessibilityIdentifier() throws {
        XCTAssertNoThrow(
            try makeView(settings: AppSettings(defaults: defaults))
                .inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.terminologyRulesEditor),
        )
    }

    func testVocabularyControlsRemainAvailableForBothEngines() throws {
        for engine in [TranscriptionEngineSetting.parakeet, .whisperKit] {
            let settings = AppSettings(defaults: defaults)
            settings.transcriptionEngine = engine
            XCTAssertNoThrow(
                try makeView(settings: settings)
                    .inspect()
                    .find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField),
                "missing vocabulary field for \(engine)",
            )
        }
    }

    func testWhisperKitVocabularyControlAttachesTheBoundedPriorityHelp() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit

        let vocabularyControl = try makeView(settings: settings)
            .inspect()
            .form()
            .section(0)
            .hStack(3)

        XCTAssertEqual(
            try vocabularyControl.help().string(),
            TranscriptionSettingsView.vocabularyHelpText(for: .whisperKit),
        )
    }

    func testWhisperKitShowsItsVocabularyHintCapacity() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit

        XCTAssertNoThrow(
            try makeView(settings: settings)
                .inspect()
                .find(text: "When enabled, WhisperKit uses a 32-token hint; earlier terms have priority."),
        )
    }

    func testWhisperKitExperimentalVocabularyPromptWritesBackToSettings() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        let toggle = try makeView(settings: settings)
            .inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.whisperKitVocabularyPromptToggle)
            .find(ViewType.Toggle.self)

        try toggle.tap()

        XCTAssertTrue(settings.whisperKitVocabularyPromptEnabled)
    }

    func testWhisperKitExperimentalVocabularyPromptExplainsTheQualityTradeoff() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit

        XCTAssertNoThrow(
            try makeView(settings: settings)
                .inspect()
                .find(text: "Experimental: dense audio can omit whole sentences. See help for measured results; prefer Parakeet for vocabulary boosting."),
        )
    }

    func testWhisperKitExperimentalVocabularyPromptAttachesTheQualityTooltip() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        let toggle = try makeView(settings: settings)
            .inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.whisperKitVocabularyPromptToggle)
            .find(ViewType.Toggle.self)

        XCTAssertEqual(
            try toggle.help().string(),
            "Experimental. WhisperKit treats the vocabulary as a decoder hint, "
                + "not a correction. In a dense four-speaker English evaluation, a 25-content-token prompt "
                + "from this 32-token budget raised word error rate from 29% to 77% and deletions from 73 to 241. "
                + "It can omit whole sentences. Results vary by audio; prefer Parakeet for vocabulary boosting.",
        )
    }

    func testParakeetHidesWhisperKitExperimentalVocabularyPrompt() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .parakeet

        XCTAssertThrowsError(
            try makeView(settings: settings)
                .inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.whisperKitVocabularyPromptToggle),
        )
    }

    private func makeView(settings: AppSettings) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
    }
}
