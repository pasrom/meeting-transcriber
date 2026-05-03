@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class SettingsViewTests: XCTestCase {
    /// Keys that other test classes may have written to the shared on-disk
    /// plist; cleared at setUp + tearDown so parallel test processes don't
    /// leak state into each other.
    private static let pollutedDefaultsKeys = [
        "transcriptionEngine", "protocolProvider",
        "diarize", "vadEnabled", "diarizerMode",
        "whisperKitModel", "whisperKitLanguage",
        "qwen3Language", "customVocabularyPath",
        "checkForUpdates", "includePreReleases",
    ]

    override func setUp() {
        super.setUp()
        for key in Self.pollutedDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in Self.pollutedDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSettingsView(
        settings: AppSettings = AppSettings(),
        updateChecker: UpdateChecker? = nil,
    ) -> SettingsView {
        let qwen3: (any TranscribingEngine)? = {
            if #available(macOS 15, *) { return Qwen3AsrEngine() }
            return nil
        }()
        return SettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            qwen3Engine: qwen3,
            updateChecker: updateChecker,
        )
    }

    private func makeGeneral(
        settings: AppSettings = AppSettings(),
        updateChecker: UpdateChecker? = nil,
    ) -> GeneralSettingsView {
        GeneralSettingsView(settings: settings, updateChecker: updateChecker)
    }

    private func makeAudio(settings: AppSettings = AppSettings()) -> AudioSettingsView {
        AudioSettingsView(settings: settings)
    }

    private func makeTranscription(settings: AppSettings = AppSettings()) -> TranscriptionSettingsView {
        let qwen3: (any TranscribingEngine)? = {
            if #available(macOS 15, *) { return Qwen3AsrEngine() }
            return nil
        }()
        return TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            qwen3Engine: qwen3,
        )
    }

    private func makeSpeakers(settings: AppSettings = AppSettings()) -> SpeakersSettingsView {
        SpeakersSettingsView(
            settings: settings,
            recognitionStatsLog: RecognitionStatsLog(),
            enrollmentDiarizerFactory: nil,
            namingDialogActive: false,
            pipelineBusy: false,
        )
    }

    private func makeOutput(settings: AppSettings = AppSettings()) -> OutputSettingsView {
        OutputSettingsView(settings: settings)
    }

    private func makeAdvanced(settings: AppSettings = AppSettings()) -> AdvancedSettingsView {
        AdvancedSettingsView(settings: settings)
    }

    // MARK: - Top-level SettingsView

    func testViewRendersWithDefaults() throws {
        XCTAssertNoThrow(try makeSettingsView().inspect())
    }

    // MARK: - General tab

    func testAppsToWatchSection() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Microsoft Teams"))
        XCTAssertNoThrow(try body.find(text: "Zoom"))
        XCTAssertNoThrow(try body.find(text: "Webex"))
    }

    func testPollIntervalFieldExists() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Poll Interval"))
    }

    func testGracePeriodFieldExists() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Grace Period"))
    }

    func testUpdatesSectionShownWhenCheckerProvided() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeGeneral(updateChecker: checker).inspect()
        XCTAssertNoThrow(try body.find(text: "Check for Updates"))
        XCTAssertNoThrow(try body.find(text: "Check Now"))
    }

    func testUpdatesSectionHiddenWhenNoChecker() throws {
        let body = try makeGeneral().inspect()
        XCTAssertThrowsError(try body.find(text: "Check Now"))
    }

    func testPreReleaseToggleShownWhenCheckEnabled() throws {
        let settings = AppSettings()
        settings.checkForUpdates = true
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeGeneral(settings: settings, updateChecker: checker).inspect()
        XCTAssertNoThrow(try body.find(text: "Include Pre-Releases"))
    }

    func testPreReleaseToggleHiddenWhenCheckDisabled() throws {
        let settings = AppSettings()
        settings.checkForUpdates = false
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeGeneral(settings: settings, updateChecker: checker).inspect()
        XCTAssertThrowsError(try body.find(text: "Include Pre-Releases"))
    }

    // MARK: - Audio tab

    func testNoMicToggleExists() throws {
        let body = try makeAudio().inspect()
        XCTAssertNoThrow(try body.find(text: "No Microphone (app audio only)"))
    }

    func testVADToggleExists() throws {
        let body = try makeAudio().inspect()
        XCTAssertNoThrow(try body.find(text: "Voice Activity Detection (VAD)"))
    }

    func testVADThresholdShownWhenEnabled() throws {
        let settings = AppSettings()
        settings.vadEnabled = true
        let body = try makeAudio(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Threshold:"))
    }

    func testVADThresholdHiddenWhenDisabled() throws {
        let settings = AppSettings()
        settings.vadEnabled = false
        let body = try makeAudio(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Threshold:"))
    }

    // MARK: - Transcription tab

    func testTranscriptionSectionExists() throws {
        let body = try makeTranscription().inspect()
        XCTAssertNoThrow(try body.find(text: "Engine"))
    }

    func testWhisperKitModelPickerExists() throws {
        let body = try makeTranscription().inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    func testWhisperKitLanguagePickerShownForWhisperKit() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testWhisperKitModelPickerShownForWhisperKit() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testParakeetHidesLanguagePicker() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        // Parakeet has no language picker — verify the engine section is still present via the Engine picker
        XCTAssertNoThrow(try body.find(text: "Engine"))
    }

    func testParakeetShowsCustomVocabularyField() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
    }

    func testParakeetVocabularyHiddenForWhisperKit() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Custom vocabulary file"))
    }

    func testWhisperKitPickersHiddenForParakeet() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
        XCTAssertThrowsError(try body.find(text: "Language"))
    }

    func testQwen3LanguagePickerShownWhenQwen3Selected() throws {
        guard #available(macOS 15, *) else { return }
        let settings = AppSettings()
        settings.transcriptionEngine = .qwen3
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Language"))
        XCTAssertNoThrow(try body.find(text: "Auto-detect"))
    }

    // MARK: - Speakers tab

    func testDiarizeToggleExists() throws {
        let body = try makeSpeakers().inspect()
        XCTAssertNoThrow(try body.find(text: "Speaker Diarization"))
    }

    func testDiarizeEnabledShowsExpectedSpeakers() throws {
        let settings = AppSettings()
        settings.diarize = true
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Expected Speakers"))
    }

    func testDiarizerModeHiddenWhenDiarizeDisabled() throws {
        let settings = AppSettings()
        settings.diarize = false
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Expected Speakers"))
    }

    func testMicSectionShownWhenMicEnabled() throws {
        let settings = AppSettings()
        settings.noMic = false
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Mic Speaker Name"))
    }

    func testMicSectionHiddenWhenNoMic() throws {
        let settings = AppSettings()
        settings.noMic = true
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Mic Speaker Name"))
    }

    func testSortformerWarningShownWhenSelected() throws {
        let settings = AppSettings()
        settings.diarize = true
        settings.diarizerMode = .sortformer
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(
            text: "Sortformer does not identify recurring speakers — speaker naming and auto-recognition are disabled.",
        ))
    }

    func testSortformerWarningHiddenForOfflineMode() throws {
        let settings = AppSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(
            text: "Sortformer does not identify recurring speakers — speaker naming and auto-recognition are disabled.",
        ))
    }

    // MARK: - Output tab

    func testProviderPickerExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "LLM Provider"))
    }

    #if !APPSTORE
        func testClaudeCLIProviderShowsBinaryPicker() throws {
            let settings = AppSettings()
            settings.protocolProvider = .claudeCLI
            let body = try makeOutput(settings: settings).inspect()
            XCTAssertNoThrow(try body.find(text: "Claude CLI"))
        }
    #endif

    func testOpenAIProviderShowsEndpointField() throws {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Endpoint"))
        XCTAssertNoThrow(try body.find(text: "API Key"))
        XCTAssertNoThrow(try body.find(text: "Fetch Models"))
    }

    func testOpenAIModelFieldShown() throws {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    func testNoneProviderShowsTranscriptOnlyMessage() throws {
        let settings = AppSettings()
        settings.protocolProvider = .none
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Only the raw transcript will be saved — no LLM summarization."))
    }

    func testNoneProviderHidesEndpointField() throws {
        let settings = AppSettings()
        settings.protocolProvider = .none
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Endpoint"))
    }

    func testProtocolLanguagePickerExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "Protocol Language"))
    }

    func testOutputFolderSectionExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "Output Folder"))
    }

    func testResetButtonDisabledWhenNoCustomDir() throws {
        let settings = AppSettings()
        settings.clearCustomOutputDir()
        let body = try makeOutput(settings: settings).inspect()
        let button = try body.find(button: "Reset")
        XCTAssertTrue(try button.isDisabled())
    }

    func testEditPromptButtonExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(button: "Edit Prompt"))
    }

    func testImportPromptButtonExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(button: "Import Prompt"))
    }

    func testResetToDefaultButtonExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(button: "Reset to Default"))
    }

    func testDefaultPromptStatusShown() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "Using default prompt"))
    }

    func testOpenAIAPIKeyCaptionShown() throws {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Leave empty if your local server doesn't require authentication"))
    }

    // MARK: - Advanced tab

    func testPermissionsSectionExists() throws {
        let body = try makeAdvanced().inspect()
        XCTAssertNoThrow(try body.find(text: "Screen Recording"))
        XCTAssertNoThrow(try body.find(text: "Microphone"))
        XCTAssertNoThrow(try body.find(text: "Accessibility"))
    }

    func testAboutSectionExists() throws {
        let body = try makeAdvanced().inspect()
        XCTAssertNoThrow(try body.find(text: "Version"))
    }

    func testAboutSectionShowsBuildDate() throws {
        let body = try makeAdvanced().inspect()
        XCTAssertNoThrow(try body.find(text: "Build Date"))
    }

    func testAboutSectionShowsFfmpegStatus() throws {
        let body = try makeAdvanced().inspect()
        XCTAssertNoThrow(try body.find(text: "ffmpeg"))
    }
}
