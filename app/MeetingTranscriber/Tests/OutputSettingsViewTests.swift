@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class OutputSettingsViewTests: XCTestCase {
    // MARK: - OutputSettingsLogic.displayPath

    func testDisplayPathAbbreviatesHomePrefix() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alice/Documents/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "~/Documents/Meetings",
        )
    }

    func testDisplayPathReturnsFullPathOutsideHome() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Volumes/External/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Volumes/External/Meetings",
        )
    }

    func testDisplayPathExactlyHomeReturnsTilde() {
        let home = URL(fileURLWithPath: "/Users/alice")
        XCTAssertEqual(OutputSettingsLogic.displayPath(for: home, home: home), "~")
    }

    func testDisplayPathDifferentUserHomeReturnsFull() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/bob/Documents")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/bob/Documents",
        )
    }

    /// Regression guard: a naive `hasPrefix` match treats `/Users/alicebob/foo`
    /// as inside `/Users/alice` and yields `~bob/foo`. Boundary must be a path
    /// component (`/` or end-of-string).
    func testDisplayPathDoesNotMatchAcrossComponentBoundary() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alicebob/foo")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/alicebob/foo",
        )
    }

    // MARK: - OutputSettingsLogic.retentionDaysLabel

    func testRetentionDaysLabelSpellsOutZeroAndSingular() {
        XCTAssertEqual(OutputSettingsLogic.retentionDaysLabel(0), "0 days (right away)")
        XCTAssertEqual(OutputSettingsLogic.retentionDaysLabel(1), "1 day")
        XCTAssertEqual(OutputSettingsLogic.retentionDaysLabel(30), "30 days")
    }

    // MARK: - OutputSettingsLogic.mergePickerOptions

    func testMergePickerOptionsPrependsSelectedWhenAbsent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "custom-tag:latest",
        )
        XCTAssertEqual(result, ["custom-tag:latest", "gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedWhenSelectedPresent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedForEmptySelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4"], selected: "",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableYieldsJustSelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: [], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableAndEmptySelectedYieldsEmpty() {
        let result = OutputSettingsLogic.mergePickerOptions(available: [], selected: "")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Protocol language list

    func testProtocolLanguagesContainNoDuplicates() {
        // The picker uses the names as ForEach ids, so a repeat would collide.
        let languages = AppSettings.protocolLanguages
        XCTAssertEqual(languages.count, Set(languages).count)
    }

    // MARK: - Render

    func testViewRendersWithDefaultSettings() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        let view = OutputSettingsView(settings: settings)
        XCTAssertNoThrow(try view.inspect())
    }

    func testOpenAIProviderExplainsConnectionsAndTheirSettingsInHelp() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        let body = try OutputSettingsView(settings: settings).inspect()
        let helpTexts = try body.findAll(HelpBadge.self).map { try $0.actualView().text }

        XCTAssertTrue(helpTexts.contains(SettingsHelp.openAIProvider))
        XCTAssertTrue(helpTexts.contains(SettingsHelp.openAIConnection))
        XCTAssertNoThrow(try body.find(text: "Connection Settings"))
    }

    func testAdvancedIsCollapsedForAValidHeaderName() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "x-api-key"
        let body = try OutputSettingsView(settings: settings).inspect()

        // The Advanced row renders, so the missing picker is not a failed lookup.
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAdvancedToggle))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker))
    }

    func testAnInvalidHeaderNameKeepsAdvancedOpen() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "Content-Type"
        let body = try OutputSettingsView(settings: settings).inspect()

        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameWarning))
    }

    func testResetPromptIsDisabledWithoutACustomPrompt() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        let body = try OutputSettingsView(settings: settings).inspect()

        XCTAssertTrue(try body.find(button: "Reset to Default\u{2026}").isDisabled())
        XCTAssertFalse(try body.find(button: "Import Prompt\u{2026}").isDisabled())
    }

    func testNoneProviderHidesPromptControls() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .none
        let body = try OutputSettingsView(settings: settings).inspect()
        // The language picker renders, so the missing prompt row is not a failed lookup.
        XCTAssertNoThrow(try body.find(text: "Notes Language"))
        XCTAssertThrowsError(try body.find(button: "Edit\u{2026}"))
    }

    #if !APPSTORE
        func testClaudeCLIProviderExplainsItselfInHelpAndKeepsTheBillingNoteInView() throws {
            let settings = AppSettings(defaults: makeIsolatedDefaults())
            settings.protocolProvider = .claudeCLI
            let body = try OutputSettingsView(settings: settings).inspect()
            XCTAssertNoThrow(try body.find(HelpBadge.self) { try $0.actualView().text == SettingsHelp.claudeCLIProvider })
            XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.claudeAPIKeyBillingNote))
        }

        func testClaudeCLIProviderHidesConnectionSettings() throws {
            let settings = AppSettings(defaults: makeIsolatedDefaults())
            settings.protocolProvider = .claudeCLI
            let body = try OutputSettingsView(settings: settings).inspect()
            // The binary picker renders, so the missing section is not a failed lookup.
            XCTAssertNoThrow(try body.find(text: "Claude CLI"))
            XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionSection))
        }
    #endif

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OutputSettingsViewTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        guard let defaults = DefaultsSuite.open(suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        return defaults
    }

    // MARK: - importPrompt

    func testImportPromptInstallsTheFirstPrompt() throws {
        let dir = try makeTempDirectory(prefix: "prompt-import")
        let source = dir.appendingPathComponent("mine.md")
        let dest = dir.appendingPathComponent("protocol_prompt.md")
        try "new".write(to: source, atomically: true, encoding: .utf8)

        try OutputSettingsLogic.importPrompt(from: source, to: dest)

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new")
    }

    /// Replacing an existing prompt used to move the picked file into place,
    /// so the import deleted the user's own file from their folder.
    func testImportPromptOverAnExistingPromptKeepsThePickedFile() throws {
        let dir = try makeTempDirectory(prefix: "prompt-import")
        let source = dir.appendingPathComponent("mine.md")
        let dest = dir.appendingPathComponent("protocol_prompt.md")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        try "old".write(to: dest, atomically: true, encoding: .utf8)

        try OutputSettingsLogic.importPrompt(from: source, to: dest)

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new")
    }
}
