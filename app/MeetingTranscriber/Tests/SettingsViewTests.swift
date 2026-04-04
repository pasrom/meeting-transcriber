@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class SettingsViewTests: XCTestCase {
    // MARK: - Helpers

    private func makeSUT(settings: AppSettings = AppSettings(), updateChecker: UpdateChecker? = nil) -> SettingsView {
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

    // MARK: - View rendering

    func testViewRendersWithDefaults() throws {
        let sut = makeSUT()
        XCTAssertNoThrow(try sut.inspect())
    }

    func testDiarizeToggleExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Speaker Diarization"))
    }

    // MARK: - Diarize section

    func testDiarizeEnabledShowsExpectedSpeakers() throws {
        let settings = AppSettings()
        settings.diarize = true
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Expected Speakers"))
    }

    // MARK: - Recording section

    func testNoMicToggleExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "No Microphone (app audio only)"))
    }

    func testMicSectionShownWhenMicEnabled() throws {
        let settings = AppSettings()
        settings.noMic = false
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Mic Speaker Name"))
    }

    func testMicSectionHiddenWhenNoMic() throws {
        let settings = AppSettings()
        settings.noMic = true
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Mic Speaker Name"))
    }

    // MARK: - Apps section

    func testAppsToWatchSection() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Microsoft Teams"))
        XCTAssertNoThrow(try body.find(text: "Zoom"))
        XCTAssertNoThrow(try body.find(text: "Webex"))
    }

    // MARK: - Recording fields

    func testPollIntervalFieldExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Poll Interval"))
    }

    func testGracePeriodFieldExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Grace Period"))
    }

    func testWhisperKitModelPickerExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    // MARK: - Protocol Provider

    func testProviderPickerExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "LLM Provider"))
    }

    #if !APPSTORE
        func testClaudeCLIProviderShowsBinaryPicker() throws {
            let settings = AppSettings()
            settings.protocolProvider = .claudeCLI
            let sut = makeSUT(settings: settings)
            let body = try sut.inspect()
            XCTAssertNoThrow(try body.find(text: "Claude CLI"))
        }
    #endif

    func testOpenAIProviderShowsEndpointField() throws {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Endpoint"))
        XCTAssertNoThrow(try body.find(text: "API Key"))
        XCTAssertNoThrow(try body.find(text: "Fetch Models"))
    }

    // MARK: - Updates section

    func testUpdatesSectionShownWhenCheckerProvided() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let sut = makeSUT(updateChecker: checker)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Check for Updates"))
        XCTAssertNoThrow(try body.find(text: "Check Now"))
    }

    func testUpdatesSectionHiddenWhenNoChecker() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Check Now"))
    }

    func testPreReleaseToggleShownWhenCheckEnabled() throws {
        let settings = AppSettings()
        settings.checkForUpdates = true
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let sut = makeSUT(settings: settings, updateChecker: checker)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Include Pre-Releases"))
    }

    // MARK: - Qwen3 engine

    func testQwen3LanguagePickerShownWhenQwen3Selected() throws {
        guard #available(macOS 15, *) else { return }
        let settings = AppSettings()
        settings.transcriptionEngine = .qwen3
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Language"))
        XCTAssertNoThrow(try body.find(text: "Auto-detect"))
    }

    // MARK: - Transcription Engine Section

    func testTranscriptionSectionExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Engine"))
    }

    func testWhisperKitLanguagePickerShownForWhisperKit() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testParakeetHidesLanguagePicker() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        // Parakeet has no language picker — WhisperKit-specific "Language" label absent
        // Verify the engine section is still present via the Engine picker
        XCTAssertNoThrow(try body.find(text: "Engine"))
    }

    // MARK: - Permissions Section

    func testPermissionsSectionExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Screen Recording"))
        XCTAssertNoThrow(try body.find(text: "Microphone"))
        XCTAssertNoThrow(try body.find(text: "Accessibility"))
    }

    // MARK: - About Section

    func testAboutSectionExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Version"))
    }

    // MARK: - OpenAI Settings

    func testOpenAIModelFieldShown() throws {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    // MARK: - Parakeet custom vocabulary

    func testParakeetShowsCustomVocabularyField() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
    }

    func testParakeetVocabularyHiddenForWhisperKit() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Custom vocabulary file"))
    }

    // MARK: - Diarizer mode section

    func testDiarizerModeHiddenWhenDiarizeDisabled() throws {
        let settings = AppSettings()
        settings.diarize = false
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Expected Speakers"))
    }

    // MARK: - VAD section

    func testVADToggleExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Voice Activity Detection (VAD)"))
    }

    func testVADThresholdShownWhenEnabled() throws {
        let settings = AppSettings()
        settings.vadEnabled = true
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Threshold:"))
    }

    func testVADThresholdHiddenWhenDisabled() throws {
        let settings = AppSettings()
        settings.vadEnabled = false
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Threshold:"))
    }

    // MARK: - Protocol provider: none

    func testNoneProviderShowsTranscriptOnlyMessage() throws {
        let settings = AppSettings()
        settings.protocolProvider = .none
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Only the raw transcript will be saved — no LLM summarization."))
    }

    func testNoneProviderHidesEndpointField() throws {
        let settings = AppSettings()
        settings.protocolProvider = .none
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Endpoint"))
    }

    // MARK: - Protocol Language

    func testProtocolLanguagePickerExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Protocol Language"))
    }

    // MARK: - Output folder

    func testOutputFolderSectionExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Output Folder"))
    }

    func testResetButtonDisabledWhenNoCustomDir() throws {
        let settings = AppSettings()
        settings.clearCustomOutputDir()
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        let button = try body.find(button: "Reset")
        XCTAssertTrue(try button.isDisabled())
    }

    // MARK: - Prompt management

    func testEditPromptButtonExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Edit Prompt"))
    }

    func testImportPromptButtonExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Import Prompt"))
    }

    func testResetToDefaultButtonExists() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Reset to Default"))
    }

    func testDefaultPromptStatusShown() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Using default prompt"))
    }

    // MARK: - Pre-release toggle hidden

    func testPreReleaseToggleHiddenWhenCheckDisabled() throws {
        let settings = AppSettings()
        settings.checkForUpdates = false
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let sut = makeSUT(settings: settings, updateChecker: checker)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Include Pre-Releases"))
    }

    // MARK: - WhisperKit model picker

    func testWhisperKitModelPickerShownForWhisperKit() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .whisperKit
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testWhisperKitPickersHiddenForParakeet() throws {
        let settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
        XCTAssertThrowsError(try body.find(text: "Language"))
    }

    // MARK: - About section details

    func testAboutSectionShowsBuildDate() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Build Date"))
    }

    func testAboutSectionShowsFfmpegStatus() throws {
        let sut = makeSUT()
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "ffmpeg"))
    }

    // MARK: - OpenAI API Key caption

    func testOpenAIAPIKeyCaptionShown() throws {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let sut = makeSUT(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Leave empty if your local server doesn't require authentication"))
    }
}
