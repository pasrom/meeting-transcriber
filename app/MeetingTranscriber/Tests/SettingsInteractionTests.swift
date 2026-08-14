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
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    // MARK: - Echo cancellation toggle

    /// One wiring test for the control, per the repo's GUI-testing rule: the
    /// decision logic is covered at the value layer, so all this has to prove
    /// is that the switch is connected to the setting the pipeline reads.
    func testEchoCancellationToggleWritesBackToSettings() throws {
        let settings = makeSettings()
        XCTAssertTrue(settings.echoCancellationEnabled, "on by default: an affected recording is broken either way")

        // The identifier sits on the `HelpfulToggle` wrapper, which renders the
        // real `Toggle` inside a row with its help badge — so reach through it
        // rather than asserting on the wrapper.
        let view = AudioSettingsView(settings: settings)
        let row = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.echoCancellationToggle)
        try row.find(ViewType.Toggle.self).tap()

        XCTAssertFalse(settings.echoCancellationEnabled, "tapping the switch must reach the setting the queue reads")
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

    // MARK: - Stepper write-back

    func testPollIntervalStepperIncrementsSetting() throws {
        let settings = makeSettings()
        settings.pollInterval = 5.0
        let view = GeneralSettingsView(settings: settings, updateChecker: nil)

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
        let view = GeneralSettingsView(settings: settings, updateChecker: nil)

        // Grace is the second stepper in document order (step 1).
        let steppers = try view.inspect().findAll(ViewType.Stepper.self)
        XCTAssertGreaterThanOrEqual(steppers.count, 2, "expected poll-interval + grace steppers")
        try steppers[1].increment()

        XCTAssertEqual(settings.endGrace, 6.0, accuracy: 0.0001, "stepping (step 1) must write back to endGrace")
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
