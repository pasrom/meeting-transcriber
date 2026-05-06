@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class SettingsViewTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite — same pattern as AppSettingsTests.
    /// Avoids `swift test --parallel` plist races AND prevents test pollution
    /// from leaking into the dev app's `.standard` plist when a test process
    /// is killed before tearDown runs.
    override func setUp() {
        super.setUp()
        testSuiteName = "SettingsViewTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    private func makeSettingsView(
        settings: AppSettings? = nil,
        updateChecker: UpdateChecker? = nil,
    ) -> SettingsView {
        let qwen3: (any TranscribingEngine)? = {
            if #available(macOS 15, *) { return Qwen3AsrEngine() }
            return nil
        }()
        return SettingsView(
            settings: settings ?? makeSettings(),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            qwen3Engine: qwen3,
            updateChecker: updateChecker,
        )
    }

    private func makeGeneral(
        settings: AppSettings? = nil,
        updateChecker: UpdateChecker? = nil,
    ) -> GeneralSettingsView {
        GeneralSettingsView(settings: settings ?? makeSettings(), updateChecker: updateChecker)
    }

    private func makeAudio(settings: AppSettings? = nil) -> AudioSettingsView {
        AudioSettingsView(settings: settings ?? makeSettings())
    }

    private func makeTranscription(settings: AppSettings? = nil) -> TranscriptionSettingsView {
        let qwen3: (any TranscribingEngine)? = {
            if #available(macOS 15, *) { return Qwen3AsrEngine() }
            return nil
        }()
        return TranscriptionSettingsView(
            settings: settings ?? makeSettings(),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            qwen3Engine: qwen3,
        )
    }

    private func makeSpeakers(
        settings: AppSettings? = nil,
        matcherFactory: @escaping () -> SpeakerMatcher = { SpeakerMatcher() },
    ) -> SpeakersSettingsView {
        SpeakersSettingsView(
            settings: settings ?? makeSettings(),
            recognitionStatsLog: RecognitionStatsLog(),
            enrollmentDiarizerFactory: nil,
            namingDialogActive: false,
            pipelineBusy: false,
            matcherFactory: matcherFactory,
        )
    }

    private func makeOutput(settings: AppSettings? = nil) -> OutputSettingsView {
        OutputSettingsView(settings: settings ?? makeSettings())
    }

    private func makeAdvanced(settings: AppSettings? = nil) -> AdvancedSettingsView {
        AdvancedSettingsView(settings: settings ?? makeSettings())
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
        let settings = makeSettings()
        settings.checkForUpdates = true
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeGeneral(settings: settings, updateChecker: checker).inspect()
        XCTAssertNoThrow(try body.find(text: "Include Pre-Releases"))
    }

    func testPreReleaseToggleHiddenWhenCheckDisabled() throws {
        let settings = makeSettings()
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
        let settings = makeSettings()
        settings.vadEnabled = true
        let body = try makeAudio(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Threshold:"))
    }

    func testVADThresholdHiddenWhenDisabled() throws {
        let settings = makeSettings()
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
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testWhisperKitModelPickerShownForWhisperKit() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testParakeetHidesLanguagePicker() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        // Parakeet has no language picker — verify the engine section is still present via the Engine picker
        XCTAssertNoThrow(try body.find(text: "Engine"))
    }

    func testParakeetShowsCustomVocabularyField() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
    }

    func testParakeetVocabularyHiddenForWhisperKit() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Custom vocabulary file"))
    }

    func testWhisperKitPickersHiddenForParakeet() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
        XCTAssertThrowsError(try body.find(text: "Language"))
    }

    func testQwen3LanguagePickerShownWhenQwen3Selected() throws {
        guard #available(macOS 15, *) else { return }
        let settings = makeSettings()
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
        let settings = makeSettings()
        settings.diarize = true
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Expected Speakers"))
    }

    func testDiarizerModeHiddenWhenDiarizeDisabled() throws {
        let settings = makeSettings()
        settings.diarize = false
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Expected Speakers"))
    }

    func testMicSectionShownWhenMicEnabled() throws {
        let settings = makeSettings()
        settings.noMic = false
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Mic Speaker Name"))
    }

    func testMicSectionHiddenWhenNoMic() throws {
        let settings = makeSettings()
        settings.noMic = true
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Mic Speaker Name"))
    }

    func testSortformerWarningShownWhenSelected() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .sortformer
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(
            text: "Sortformer does not identify recurring speakers — speaker naming and auto-recognition are disabled.",
        ))
    }

    func testSortformerWarningHiddenForOfflineMode() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(
            text: "Sortformer does not identify recurring speakers — speaker naming and auto-recognition are disabled.",
        ))
    }

    // SpeakerMatcher.init reads + decodes speakers.json. It must run only
    // when the user opens the Known Voices sheet, never as a side effect
    // of body evaluation.
    func testKnownVoicesMatcherNotCreatedOnBodyEval() throws {
        var matcherInits = 0
        let view = makeSpeakers {
            matcherInits += 1
            return SpeakerMatcher()
        }
        _ = try view.inspect()
        XCTAssertEqual(matcherInits, 0)
    }

    // Companion: tapping "Manage…" invokes the factory exactly once.
    func testKnownVoicesMatcherCreatedOnManageTap() throws {
        var matcherInits = 0
        let view = makeSpeakers {
            matcherInits += 1
            return SpeakerMatcher()
        }
        let button = try view.inspect().find(button: "Manage\u{2026}")
        try button.tap()
        XCTAssertEqual(matcherInits, 1)
    }

    // MARK: - Output tab

    func testProviderPickerExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "LLM Provider"))
    }

    #if !APPSTORE
        func testClaudeCLIProviderShowsBinaryPicker() throws {
            let settings = makeSettings()
            settings.protocolProvider = .claudeCLI
            let body = try makeOutput(settings: settings).inspect()
            XCTAssertNoThrow(try body.find(text: "Claude CLI"))
        }
    #endif

    func testOpenAIProviderShowsEndpointField() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Endpoint"))
        XCTAssertNoThrow(try body.find(text: "API Key"))
        XCTAssertNoThrow(try body.find(text: "Fetch Models"))
    }

    func testOpenAIModelFieldShown() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    func testNoneProviderShowsTranscriptOnlyMessage() throws {
        let settings = makeSettings()
        settings.protocolProvider = .none
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Only the raw transcript will be saved — no LLM summarization."))
    }

    func testNoneProviderHidesEndpointField() throws {
        let settings = makeSettings()
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
        let settings = makeSettings()
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
        let settings = makeSettings()
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

    #if !APPSTORE
        func testDebugRPCToggleExists() throws {
            let body = try makeAdvanced().inspect()
            XCTAssertNoThrow(try body.find(text: "Debug RPC Server"))
        }

        func testDebugRPCToggleBindsToSetting() throws {
            let settings = makeSettings()
            settings.debugRPCEnabled = false
            let view = AdvancedSettingsView(settings: settings)
            let toggle = try view.inspect().find(ViewType.Toggle.self) { toggle in
                try toggle.labelView().text().string() == "Debug RPC Server"
            }
            try toggle.tap()
            XCTAssertTrue(settings.debugRPCEnabled)
        }
    #endif

    // MARK: - Record-only mode

    func testRecordOnlyToggleExists() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Record-only mode"))
    }

    func testRecordOnlyBannerHiddenWhenOff() throws {
        let settings = makeSettings()
        settings.recordOnly = false
        let body = try makeGeneral(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: "recordOnlyBanner"))
    }

    func testRecordOnlyBannerVisibleWhenOn() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeGeneral(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: "recordOnlyBanner"))
    }

    func testRecordOnlyDisablesTranscriptionSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeTranscription(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: "transcriptionSection")
        XCTAssertTrue(try section.isDisabled())
    }

    func testRecordOnlyDisablesProtocolSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeOutput(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: "protocolSection")
        XCTAssertTrue(try section.isDisabled())
    }

    func testRecordOnlyDoesNotDisableOutputFolderSection() throws {
        // Output Folder is where WAVs land in record-only mode too,
        // so it must remain interactive when the rest of Output is dimmed.
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeOutput(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: "outputFolderSection")
        XCTAssertFalse(try section.isDisabled())
    }

    func testRecordOnlyDisablesDiarizationSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeSpeakers(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: "diarizationSection")
        XCTAssertTrue(try section.isDisabled())
    }

    func testRecordOnlyDisablesVadSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeAudio(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: "vadSection")
        XCTAssertTrue(try section.isDisabled())
    }
}
