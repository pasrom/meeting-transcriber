@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// One wiring test per "Transcribe with" control in Settings → Transcribe:
/// the dropdown, the rows each method shows, the consent alert's two buttons,
/// the cloud fields and the shared Vocabulary section.
@MainActor
final class TranscriptionSettingsCloudTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keyAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsCloudTests-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
        // Never the production account: see `AppSettings.apiKeyAccount`.
        keyAccount = "TranscriptionSettingsCloudTests-key-\(getpid())-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        KeychainHelper.delete(key: keyAccount + ".alternate")
        KeychainHelper.delete(key: keyAccount)
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        keyAccount = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, cloudTranscriptionAPIKeyAccount: keyAccount)
    }

    private func makeView(_ settings: AppSettings) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
    }

    private func selectMethod(_ method: TranscriptionMethod, in view: TranscriptionSettingsView) throws {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.transcriptionMethodPicker)
            .find(ViewType.Picker.self)
            .select(value: method)
    }

    private static let cloudRows = [
        A11yID.cloudTranscriptionHostNote, A11yID.cloudTranscriptionBaseURLField,
        A11yID.cloudTranscriptionModelField, A11yID.cloudTranscriptionAPIKeyField,
        A11yID.cloudTranscriptionTestButton, A11yID.cloudTranscriptionLanguagePicker,
        A11yID.cloudTranscriptionLocalFallbackNote,
    ]

    private static let localWhisperKitRows = [
        A11yID.whisperKitModelPicker, A11yID.unloadModelsWhenIdleToggle,
    ]

    // MARK: - Dropdown and visible rows

    func testDropdownLeadsTheTranscriptionSectionAndRecordOnlyDisablesIt() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let section = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.transcriptionSection)
        let picker = try section.find(viewWithAccessibilityIdentifier: A11yID.transcriptionMethodPicker)
            .find(ViewType.Picker.self)
        XCTAssertEqual(try picker.labelView().text().string(), "Transcribe with")
        XCTAssertNoThrow(try picker.find(text: "Local"))
        XCTAssertNoThrow(try picker.find(text: "Cloud"))
        XCTAssertTrue(section.isDisabled())
    }

    func testOnThisMacShowsOnlyTheLocalRows() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeView(settings).inspect()

        for id in Self.localWhisperKitRows {
            XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: id), id)
        }
        XCTAssertNoThrow(try body.find(button: "Load Model"), "model status row")
        for id in Self.cloudRows {
            XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: id), id)
        }
    }

    func testCloudShowsOnlyTheCloudRows() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        settings.cloudTranscriptionEnabled = true
        let section = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.transcriptionSection)

        for id in Self.cloudRows {
            XCTAssertNoThrow(try section.find(viewWithAccessibilityIdentifier: id), id)
        }
        for id in Self.localWhisperKitRows {
            XCTAssertThrowsError(try section.find(viewWithAccessibilityIdentifier: id), id)
        }
        XCTAssertThrowsError(try section.find(button: "Load Model"), "no model status in Cloud")
        XCTAssertThrowsError(
            try section.find(ViewType.Picker.self) { try $0.labelView().text().string() == "Engine" },
            "no engine picker in Cloud",
        )
    }

    // MARK: - Consent alert

    func testFirstPickOfCloudAsksAndCancelLeavesOnThisMac() throws {
        let settings = makeSettings()
        let view = makeView(settings)

        try selectMethod(.cloud, in: view)
        XCTAssertFalse(settings.cloudTranscriptionEnabled, "nothing may switch on before the user confirms")
        let alert = try view.inspect().find(ViewType.Alert.self)
        try alert.actions().find(button: "Cancel").tap()

        XCTAssertFalse(settings.cloudTranscriptionEnabled)
        XCTAssertFalse(settings.cloudTranscriptionConsented)
        XCTAssertThrowsError(try view.inspect().find(ViewType.Alert.self), "the alert must close on Cancel")
        let selected = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.transcriptionMethodPicker)
            .find(ViewType.Picker.self)
            .selectedValue(TranscriptionMethod.self)
        XCTAssertEqual(selected, .onThisMac, "the dropdown must return to Local")
    }

    func testConfirmSwitchesToCloudAndIsRemembered() throws {
        let settings = makeSettings()
        let view = makeView(settings)

        try selectMethod(.cloud, in: view)
        try view.inspect().find(ViewType.Alert.self).actions().find(button: "Send to Cloud").tap()

        XCTAssertTrue(settings.cloudTranscriptionEnabled)
        XCTAssertTrue(settings.cloudTranscriptionConsented)
        XCTAssertTrue(makeSettings().cloudTranscriptionConsented, "the confirmation must persist")

        try selectMethod(.onThisMac, in: view)
        XCTAssertFalse(settings.cloudTranscriptionEnabled)
        try selectMethod(.cloud, in: view)
        XCTAssertTrue(settings.cloudTranscriptionEnabled, "a later pick of Cloud must not ask again")
        XCTAssertThrowsError(try view.inspect().find(ViewType.Alert.self))
    }

    // MARK: - Run Locally fallback line

    func testFallbackLineNamesTheLocalEngineAndModel() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        settings.transcriptionEngine = .whisperKit
        settings.whisperKitModel = "openai_whisper-large-v3-v20240930_turbo"
        let line = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionLocalFallbackNote)
            .text()
            .string()
        XCTAssertEqual(line, "Run Locally uses WhisperKit \u{00B7} Large V3 Turbo")

        settings.whisperKitModel = "openai_whisper-small"
        XCTAssertEqual(TranscriptionSettingsView.localFallbackDescription(for: settings), "Run Locally uses WhisperKit \u{00B7} Small")

        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "someone/whisper-fine-tunes"
        settings.whisperKitCustomVariant = "openai_whisper-small"
        XCTAssertEqual(
            TranscriptionSettingsView.localFallbackDescription(for: settings),
            "Run Locally uses WhisperKit \u{00B7} openai_whisper-small",
            "a custom model is named by its variant, not the stock label",
        )

        settings.transcriptionEngine = .parakeet
        XCTAssertEqual(TranscriptionSettingsView.localFallbackDescription(for: settings), "Run Locally uses Parakeet")
    }

    // MARK: - Cloud language

    func testCloudLanguagePickerOffersTheWhisperListAndWritesBack() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        settings.whisperLanguage = "de"
        let picker = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionLanguagePicker)
            .find(ViewType.Picker.self)
        XCTAssertNoThrow(try picker.find(text: "Auto-detect"))
        for language in PickerLanguages.whisperKit {
            XCTAssertNoThrow(try picker.find(text: language.label), "missing \(language.label)")
        }

        try picker.select(value: "id")

        XCTAssertEqual(settings.cloudTranscriptionLanguage, "id")
        XCTAssertEqual(settings.whisperLanguage, "de", "the local language is untouched")
    }

    // MARK: - Vocabulary section

    func testVocabularySectionShowsInBothMethodsWithItsHelpPerMethod() throws {
        for cloud in [false, true] {
            let settings = makeSettings()
            settings.transcriptionEngine = .parakeet
            settings.cloudTranscriptionEnabled = cloud
            settings.customVocabularyEnabled = true // the file row shows only with the switch on
            let section = try makeView(settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.vocabularySection)
            XCTAssertNoThrow(try section.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField))
            XCTAssertNoThrow(try section.find(viewWithAccessibilityIdentifier: A11yID.terminologyRulesEditor))
            XCTAssertEqual(
                try section.find(ViewType.HStack.self) { stack in
                    (try? stack.find(viewWithAccessibilityIdentifier: A11yID.customVocabularyPathField)) != nil
                }.help().string(),
                cloud ? TranscriptionSettingsView.cloudVocabularyHelpText
                    : TranscriptionSettingsView.vocabularyHelpText(for: .parakeet),
            )
        }
    }

    func testRecordOnlyDisablesTheVocabularySection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        XCTAssertTrue(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.vocabularySection).isDisabled(),
        )
    }

    // MARK: - Fields and host note

    func testHostNoteNamesTheConfiguredHostOnlyWhileCloudIsOn() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionBaseURL = "https://transcribe.example.com/v1"

        XCTAssertThrowsError(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionHostNote),
        )

        settings.cloudTranscriptionEnabled = true
        let note = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionHostNote)
            .text()
            .string()
        XCTAssertTrue(note.contains("transcribe.example.com"), note)
    }

    /// A track starting while the user types must not see a half-typed host
    /// or a new host paired with the old key, so nothing is stored until Save.
    func testBaseURLAndKeyReachSettingsTogetherOnlyOnSave() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        let saved = settings.cloudTranscriptionBaseURL
        let view = makeView(settings)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionBaseURLField)
            .find(ViewType.TextField.self)
            .setInput("https://other.example.com/v1")
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionAPIKeyField)
            .find(ViewType.SecureField.self)
            .setInput("sk-cloud")
        XCTAssertEqual(settings.cloudTranscriptionBaseURL, saved, "an edit reached settings before Save")
        XCTAssertNil(KeychainHelper.read(key: keyAccount))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionUnsavedNote))

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionSaveButton)
            .find(ViewType.Button.self)
            .tap()

        XCTAssertEqual(settings.cloudTranscriptionBaseURL, "https://other.example.com/v1")
        XCTAssertEqual(makeSettings().cloudTranscriptionAPIKey, "sk-cloud")
        let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(stored.contains("sk-cloud"), "the key must never reach UserDefaults")
    }

    func testModelFieldWritesBack() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        XCTAssertEqual(settings.cloudTranscriptionModel, "whisper-1", "default model")

        try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField)
            .find(ViewType.TextField.self)
            .setInput("whisper-large-v3")

        XCTAssertEqual(settings.cloudTranscriptionModel, "whisper-large-v3")
    }

    /// The previous endpoint's green check and model list describe nothing now.
    func testEditingTheEndpointDropsTheConnectionResultAndModelList() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        settings.cloudTranscriptionBaseURL = "https://cloud.test/v1"
        MockURLProtocol.handler = { request in
            let body = request.url?.path.hasSuffix("/models") == true
                ? #"{"data":[{"id":"whisper-1"}]}"# : #"{"segments":[]}"#
            // swiftlint:disable:next force_unwrapping
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let test = CloudConnectionTest(session: session)
        let list = CloudModelList(session: session)
        let drafts = CloudEndpointDrafts()
        drafts.load(from: settings)
        let controls = CloudTranscriptionControls(
            settings: settings, drafts: drafts, connectionTest: test, modelList: list, localFallback: "",
        )
        test.run(drafts.configuration(from: settings))
        list.fetch(baseURL: drafts.baseURL, apiKey: "")
        await test.task?.value
        await list.task?.value
        XCTAssertEqual(test.result, .success, "test premise")
        XCTAssertEqual(list.models, ["whisper-1"], "test premise")

        try controls.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionBaseURLField)
            .find(ViewType.TextField.self)
            .setInput("https://other.test/v1")

        XCTAssertNil(test.result)
        XCTAssertEqual(list.models, [])
    }

    // MARK: - Live captions note

    func testLiveCaptionsNoteShowsOnlyWhenCloudTurnsCaptionsOff() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = ""
        settings.cloudTranscriptionLanguage = ""
        settings.liveTranscriptionEnabled = true
        XCTAssertThrowsError(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsCloudOffNote),
            "no note while cloud is off",
        )

        settings.cloudTranscriptionEnabled = true
        let section = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveTranscriptionSection)
        let note = try section.find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsCloudOffNote).text().string()
        XCTAssertEqual(note, "Live captions are off for this language while cloud transcription is on.")

        settings.parakeetLanguage = "en"
        XCTAssertNoThrow(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsCloudOffNote),
            "with cloud on, captions follow the cloud language, not the local one",
        )

        settings.cloudTranscriptionLanguage = "en"
        XCTAssertThrowsError(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsCloudOffNote),
            "English captions stream without the local engine, so no note",
        )
    }

    // MARK: - Test Connection

    func testTestConnectionButtonRunsTheTestAndShowsItsResult() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        settings.cloudTranscriptionBaseURL = "https://cloud.test/v1"
        MockURLProtocol.handler = { request in
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.handler = nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let test = CloudConnectionTest(session: URLSession(configuration: sessionConfig))
        let drafts = CloudEndpointDrafts()
        drafts.load(from: settings)
        let controls = CloudTranscriptionControls(
            settings: settings, drafts: drafts, connectionTest: test, modelList: CloudModelList(), localFallback: "",
        )

        try controls.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionTestButton)
            .find(ViewType.Button.self)
            .tap()
        XCTAssertTrue(test.isRunning, "the button must start the test and show it running")
        await test.task?.value

        XCTAssertEqual(test.result, .authFailed(status: 401))
        let status = try controls.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionTestStatus)
            .find(ViewType.Text.self)
            .string()
        XCTAssertEqual(status, CloudConnectionTestResult.authFailed(status: 401).message)
    }

    // MARK: - Cloud language setting

    func testCloudLanguageStartsFromTheWhisperKitLanguageAndIsStored() {
        defaults.set("id", forKey: "whisperLanguage")
        let upgraded = makeSettings()
        XCTAssertEqual(upgraded.cloudTranscriptionLanguage, "id")
        XCTAssertEqual(defaults.string(forKey: "cloudTranscriptionLanguage"), "id")

        upgraded.whisperLanguage = "fr"
        XCTAssertEqual(makeSettings().cloudTranscriptionLanguage, "id", "once stored, it no longer follows WhisperKit's")
    }

    func testStoredCloudLanguageWinsIncludingAutoDetect() {
        defaults.set("de", forKey: "whisperLanguage")
        defaults.set("", forKey: "cloudTranscriptionLanguage")
        XCTAssertNil(makeSettings().cloudTranscriptionLanguageOrNil)
    }

    func testCaptionLanguageFollowsTheCloudLanguageOnlyWhileCloudIsOn() {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "en"
        settings.cloudTranscriptionLanguage = "de"
        XCTAssertEqual(settings.liveCaptionsLanguageOrNil, "en")
        settings.cloudTranscriptionEnabled = true
        XCTAssertEqual(settings.liveCaptionsLanguageOrNil, "de")
        settings.cloudTranscriptionLanguage = ""
        XCTAssertNil(settings.liveCaptionsLanguageOrNil)
    }

    // MARK: - Configuration

    func testConfigurationCarriesTheCloudLanguageAndVocabularyTerms() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        settings.cloudTranscriptionLanguage = "id"
        let vocabulary = FileManager.default.temporaryDirectory.appendingPathComponent("vocab_\(UUID().uuidString).txt")
        try "Acme\nSpeaker A\n".write(to: vocabulary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vocabulary) }
        settings.setCustomVocabularyPath(vocabulary.path)

        let config = settings.cloudTranscriptionConfiguration
        XCTAssertEqual(config.language, "id")
        XCTAssertEqual(config.vocabularyTerms, ["Acme", "Speaker A"])

        settings.cloudTranscriptionLanguage = ""
        settings.clearCustomVocabularyFile()
        XCTAssertNil(settings.cloudTranscriptionConfiguration.language)
        XCTAssertEqual(settings.cloudTranscriptionConfiguration.vocabularyTerms, [])
    }
}
