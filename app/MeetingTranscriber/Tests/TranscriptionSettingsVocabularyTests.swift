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
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testVocabularyPathFieldWritesBackThroughTheBookmarkSafeSetter() throws {
        let settings = AppSettings(defaults: defaults)
        settings.customVocabularyEnabled = true
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

    func testATerminologyRulesFileReplacesTheEditorWithItsReadOnlyContents() throws {
        let file = try makeTempDirectory(prefix: "terminology-view").appendingPathComponent("rules.txt")
        try "Aster => Astor\n".write(to: file, atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: defaults)
        settings.setTerminologyRulesFile(file)

        let view = try makeView(settings: settings).inspect()

        XCTAssertThrowsError(try view.find(viewWithAccessibilityIdentifier: A11yID.terminologyRulesEditor))
        let preview = try view.find(viewWithAccessibilityIdentifier: A11yID.terminologyRulesFilePreview)
        XCTAssertEqual(try preview.find(ViewType.Text.self).string(), "Aster => Astor\n")
        XCTAssertNoThrow(try view.find(text: "1 active terminology rule."))
    }

    func testTerminologyRulesFilePathFieldWritesBackThroughTheBookmarkSafeSetter() throws {
        let directory = try makeTempDirectory(prefix: "terminology-path-field")
        let selected = directory.appendingPathComponent("rules.txt")
        try "Aster => Astor\n".write(to: selected, atomically: true, encoding: .utf8)
        let typed = directory.appendingPathComponent("typed.txt").path
        let settings = AppSettings(defaults: defaults)
        settings.setTerminologyRulesFile(selected)
        XCTAssertNotNil(settings.terminologyRulesFileBookmark)
        let field = try makeView(settings: settings).inspect().find(ViewType.TextField.self) { field in
            try field.accessibilityIdentifier() == A11yID.terminologyRulesFilePathField
        }

        try field.setInput(typed)

        XCTAssertEqual(settings.terminologyRulesFilePath, typed)
        XCTAssertNil(settings.terminologyRulesFileBookmark)
        XCTAssertEqual(settings.terminologyRulesValidation, .fileUnavailable)
    }

    func testVocabularyControlsRemainAvailableForBothEngines() throws {
        for engine in [TranscriptionEngineSetting.parakeet, .whisperKit] {
            let settings = AppSettings(defaults: defaults)
            settings.transcriptionEngine = engine
            settings.customVocabularyEnabled = true
            XCTAssertNoThrow(
                try makeView(settings: settings)
                    .inspect()
                    .find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField),
                "missing vocabulary field for \(engine)",
            )
        }
    }

    func testWhisperKitVocabularyFileRowAttachesThePriorityHelp() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        settings.customVocabularyEnabled = true

        let vocabularyControl = try makeView(settings: settings)
            .inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.vocabularySection)
            .find(ViewType.HStack.self) { (try? $0.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField)) != nil }

        XCTAssertEqual(
            try vocabularyControl.help().string(),
            TranscriptionSettingsView.vocabularyHelpText(for: .whisperKit),
        )
        XCTAssertTrue(TranscriptionSettingsView.vocabularyHelpText(for: .whisperKit).contains("Earlier terms have priority"))
    }

    func testWhisperKitExperimentalVocabularyPromptWritesBackToSettings() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        let toggle = try makeView(settings: settings)
            .inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.customVocabularyToggle)
            .find(ViewType.Toggle.self)

        try toggle.tap()

        XCTAssertTrue(settings.customVocabularyEnabled)
    }

    func testWhisperKitPutsTheExperimentalWarningInTheHelpBadgeInsteadOfCaptions() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        let body = try makeView(settings: settings).inspect()

        XCTAssertEqual(
            try body.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyToggle)
                .find(HelpBadge.self).actualView().text,
            SettingsHelp.customVocabularyWhisperKit,
        )
        XCTAssertThrowsError(try body.find(text: "When enabled, WhisperKit uses a 32-token hint; earlier terms have priority."))
    }

    func testWhisperKitVocabularyPromptSitsInTheVocabularySectionAndGatesTheFileRow() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        let section = try makeView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.vocabularySection)
        XCTAssertNoThrow(try section.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyToggle))
        XCTAssertThrowsError(try section.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField))
        XCTAssertNoThrow(try section.find(viewWithAccessibilityIdentifier: A11yID.terminologyRulesEditor))

        settings.customVocabularyEnabled = true
        XCTAssertNoThrow(
            try makeView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.vocabularySection)
                .find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField),
        )
    }

    func testParakeetShowsTheSwitchAndHidesTheFileRowWhileOff() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyEnabled = false
        let section = try makeView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.vocabularySection)

        XCTAssertNoThrow(try section.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyToggle))
        XCTAssertThrowsError(try section.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField))
    }

    func testParakeetHelpBadgeIsGeneralWithoutTheWhisperKitWarning() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .parakeet

        XCTAssertEqual(
            try makeView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.customVocabularyToggle)
                .find(HelpBadge.self).actualView().text,
            SettingsHelp.customVocabulary,
        )
    }

    func testCloudHelpBadgeOmitsTheWhisperKitWarning() throws {
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperKit
        settings.cloudTranscriptionEnabled = true

        XCTAssertEqual(
            try makeView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.customVocabularyToggle)
                .find(HelpBadge.self).actualView().text,
            SettingsHelp.customVocabulary,
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
