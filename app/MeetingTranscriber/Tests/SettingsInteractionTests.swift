@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Interaction + write-back tests for non-button Settings controls (Picker,
/// Stepper) and a first LiveCaptionsOverlay render test. The existing suite drove
/// only Toggle `.tap()`; Picker `.select()` / Stepper `.increment()` / the
/// captions TimelineView had zero coverage. Each control is driven and the
/// resulting `AppSettings` write-back (or rendered identifier) is asserted, so a
/// broken binding — not just a missing control — fails the test.
@MainActor
final class SettingsInteractionTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        // Isolated per-test suite (pid+uuid) so a killed test never leaks into the
        // dev app's `.standard` plist — mirrors SettingsViewTests.
        suiteName = "SettingsInteractionTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        if let suiteName { DefaultsSuite.remove(suiteName) }
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    // MARK: - Picker write-back

    func testEnginePickerSelectionWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )

        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.labelView().text().string() == "Engine"
        }
        try picker.select(value: TranscriptionEngineSetting.parakeet)

        XCTAssertEqual(settings.transcriptionEngine, .parakeet, "selecting the picker value must flip the setting")
    }

    func testLLMProviderPickerSelectionWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.protocolProvider = .none
        let view = OutputSettingsView(settings: settings)

        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.labelView().text().string() == "LLM Provider"
        }
        try picker.select(value: ProtocolProvider.openAICompatible)

        XCTAssertEqual(settings.protocolProvider, .openAICompatible)
    }

    func testProtocolLanguagePickerOffersIndonesianAndWritesBack() throws {
        let settings = makeSettings()
        let view = OutputSettingsView(settings: settings)

        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.labelView().text().string() == "Protocol Language"
        }
        // `select(value:)` only writes the binding and never checks the tags, so
        // the option's presence has to be asserted separately.
        XCTAssertNoThrow(try picker.find(text: "Indonesian"))
        try picker.select(value: "Indonesian")

        XCTAssertEqual(settings.protocolLanguage, "Indonesian")
    }

    func testProtocolLanguagePickerKeepsAStoredLanguageMissingFromTheList() throws {
        let settings = makeSettings()
        settings.protocolLanguage = "Thai"
        XCTAssertFalse(AppSettings.protocolLanguages.contains("Thai"), "precondition: the stored value must be off-list")
        let view = OutputSettingsView(settings: settings)

        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.labelView().text().string() == "Protocol Language"
        }

        XCTAssertNoThrow(try picker.find(text: "Thai"))
    }

    func testOpenAIAPIKeyPlacementPickerWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        let view = OutputSettingsView(settings: settings)

        let picker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker)
            .find(ViewType.Picker.self)
        try picker.select(value: OpenAIAPIKeyPlacement.customHeader)

        XCTAssertEqual(settings.openAIAPIKeyPlacement, .customHeader)
    }

    func testOpenAIAPIKeyHeaderNameFieldWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        let view = OutputSettingsView(settings: settings)

        let field = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameField)
            .find(ViewType.TextField.self)
        XCTAssertNotEqual(settings.openAIAPIKeyHeaderName, "x-api-key", "precondition: the input must differ from the stored value")
        try field.setInput("x-api-key")

        XCTAssertEqual(settings.openAIAPIKeyHeaderName, "x-api-key")
    }

    // MARK: - OpenAI sampling overrides

    private func openAIView(temperature: Double? = nil, topP: Double? = nil) -> (OutputSettingsView, AppSettings) {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        settings.openAITemperature = temperature
        settings.openAITopP = topP
        return (OutputSettingsView(settings: settings), settings)
    }

    func testOpenAITemperatureToggleSwitchesOverrideOn() throws {
        let (view, settings) = openAIView()

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAITemperatureToggle)
            .find(ViewType.Toggle.self)
            .tap()

        XCTAssertEqual(settings.openAITemperature, OpenAISamplingParameter.initialOverride)
    }

    func testOpenAITopPToggleSwitchesOverrideOff() throws {
        let (view, settings) = openAIView(topP: 0.5)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAITopPToggle)
            .find(ViewType.Toggle.self)
            .tap()

        XCTAssertNil(settings.openAITopP, "switching the override off must clear it, not keep the last value")
    }

    func testOpenAITemperatureStepperWritesBack() throws {
        let (view, settings) = openAIView(temperature: 0.5)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAITemperatureValue)
            .find(ViewType.Stepper.self)
            .increment()

        XCTAssertEqual(try XCTUnwrap(settings.openAITemperature), 0.55, accuracy: 0.0001)
    }

    func testOpenAITopPStepperWritesBack() throws {
        let (view, settings) = openAIView(topP: 0.5)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAITopPValue)
            .find(ViewType.Stepper.self)
            .decrement()

        XCTAssertEqual(try XCTUnwrap(settings.openAITopP), 0.45, accuracy: 0.0001)
    }

    func testOpenAITemperatureFieldWritesBack() throws {
        let (view, settings) = openAIView(temperature: 0.5)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAITemperatureValue)
            .find(ViewType.TextField.self)
            // The field parses with the current locale, so type what it would show.
            .setInput(0.2.formatted(.number))

        XCTAssertEqual(settings.openAITemperature, 0.2)
    }

    func testOpenAITopPFieldWritesBack() throws {
        let (view, settings) = openAIView(topP: 0.5)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAITopPValue)
            .find(ViewType.TextField.self)
            .setInput(0.9.formatted(.number))

        XCTAssertEqual(settings.openAITopP, 0.9)
    }

    func testOpenAISamplingValueRowsOnlyAppearWhenOverridden() throws {
        let body = try openAIView(temperature: 0.7).0.inspect()

        // The top_p toggle renders, so the missing value row is not a failed lookup.
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.openAITopPToggle))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.openAITemperatureValue))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openAITopPValue))
    }

    func testOpenAIAPIKeyHeaderNameControlsOnlyAppearForCustomHeader() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .bearerToken
        settings.openAIAPIKeyHeaderName = "Content-Type"
        let body = try OutputSettingsView(settings: settings).inspect()

        // The placement picker renders, so the absences below are not a failed lookup.
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameField))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameWarning))
    }

    func testOpenAIAPIKeyHeaderNameWarningShownOnlyForInvalidName() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader

        settings.openAIAPIKeyHeaderName = "Content-Type"
        XCTAssertNoThrow(
            try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameWarning),
        )

        settings.openAIAPIKeyHeaderName = "x-api-key"
        XCTAssertThrowsError(
            try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameWarning),
        )

        // The generator trims the name before it validates it, so the warning must too.
        settings.openAIAPIKeyHeaderName = " x-api-key "
        XCTAssertThrowsError(
            try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameWarning),
        )
    }

    // MARK: - Transcript output toggles

    func testIncludeFullTranscriptToggleWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.includeFullTranscriptInProtocol = true
        let view = OutputSettingsView(settings: settings)

        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.includeFullTranscriptToggle)
            .find(ViewType.Toggle.self)
        try toggle.tap()

        XCTAssertFalse(settings.includeFullTranscriptInProtocol)
    }

    func testSaveRawTranscriptToggleWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.saveRawTranscriptSeparately = true
        let view = OutputSettingsView(settings: settings)

        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.saveRawTranscriptToggle)
            .find(ViewType.Toggle.self)
        try toggle.tap()

        XCTAssertFalse(settings.saveRawTranscriptSeparately)
    }

    func testUseAITitleForFilenamesToggleWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.useAITitleForFilenames = false
        let view = OutputSettingsView(settings: settings)

        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.useAITitleForFilenamesToggle)
            .find(ViewType.Toggle.self)
        try toggle.tap()

        XCTAssertTrue(settings.useAITitleForFilenames)
    }

    // MARK: - Stepper write-back

    func testPollIntervalStepperIncrementsSetting() throws {
        let settings = makeSettings()
        settings.pollInterval = 5.0
        let view = GeneralSettingsView(settings: settings)

        // Poll-interval + grace each have a Stepper; poll-interval is first in
        // document order (both have empty, hidden labels so can't be found by text).
        let steppers = try view.inspect().findAll(ViewType.Stepper.self)
        XCTAssertGreaterThanOrEqual(steppers.count, 2, "expected poll-interval + grace steppers")
        try steppers[0].increment()

        XCTAssertEqual(settings.pollInterval, 5.5, accuracy: 0.0001, "stepping (step 0.5) must write back to pollInterval")
    }

    func testGracePeriodStepperIncrementsSetting() throws {
        let settings = makeSettings()
        settings.endGrace = 5.0
        let view = GeneralSettingsView(settings: settings)

        // Grace is the second stepper in document order (step 1).
        let steppers = try view.inspect().findAll(ViewType.Stepper.self)
        XCTAssertGreaterThanOrEqual(steppers.count, 2, "expected poll-interval + grace steppers")
        try steppers[1].increment()

        XCTAssertEqual(settings.endGrace, 6.0, accuracy: 0.0001, "stepping (step 1) must write back to endGrace")
    }

    // MARK: - Live caption overlay toggle

    func testShowCaptionOverlayToggleBindsToSettings() throws {
        let settings = makeSettings()
        settings.liveTranscriptionEnabled = true
        XCTAssertTrue(settings.liveCaptionsOverlayEnabled, "precondition: overlay defaults on")
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsOverlayToggle)
            .find(ViewType.Toggle.self)
        try toggle.tap()
        XCTAssertFalse(
            settings.liveCaptionsOverlayEnabled,
            "tapping the overlay toggle must turn the setting off",
        )
    }

    func testShowCaptionOverlayToggleDisabledWhenLiveTranscriptionOff() throws {
        let settings = makeSettings()
        settings.liveTranscriptionEnabled = false
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsOverlayToggle)
        XCTAssertTrue(toggle.isDisabled())
    }

    // MARK: - Caption size picker

    func testCaptionSizePickerSelectionWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.liveTranscriptionEnabled = true
        XCTAssertEqual(settings.liveCaptionsSize, .medium, "precondition: default preset")
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )

        let picker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsSizePicker)
            .find(ViewType.Picker.self)
        try picker.select(value: LiveCaptionsSize.small)

        XCTAssertEqual(settings.liveCaptionsSize, .small, "selecting a preset must write back to settings")
    }

    /// A hidden bar has no size to pick, so the picker follows the overlay
    /// toggle exactly as that toggle follows the master switch.
    func testCaptionSizePickerDisabledWhenOverlayHidden() throws {
        let settings = makeSettings()
        settings.liveTranscriptionEnabled = true
        settings.liveCaptionsOverlayEnabled = false
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
        let picker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsSizePicker)
        XCTAssertTrue(picker.isDisabled())
    }

    // MARK: - LiveCaptionsOverlay render

    func testLiveCaptionsOverlayBackendIdentifierTracksActiveBackend() throws {
        let state = LiveCaptionsState()
        state.applyFinalized("hello", channel: .mic)

        // No active backend → the backend label (inside the TimelineView) is absent.
        XCTAssertThrowsError(
            try LiveCaptionsOverlay(state: state).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionBackend),
            "with no active backend the label must not render",
        )

        // Active backend → the label appears, reachable through the TimelineView.
        state.setActiveBackend("Parakeet EOU")
        XCTAssertNoThrow(
            try LiveCaptionsOverlay(state: state).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionBackend),
            "an active backend must render the label",
        )
    }
}
