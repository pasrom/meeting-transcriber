@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// Write-back of the Connection Settings fields, each driven through the view
/// so a wrong binding fails, and the Advanced group's open and close rules.
@MainActor
final class OpenAIConnectionSectionTests: XCTestCase {
    func testOpenAIEndpointFieldWritesBackToSettings() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        XCTAssertNotEqual(settings.openAIEndpoint, "http://gpu-box:8080/v1", "precondition: the input must differ from the stored value")

        try OutputSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIEndpointField)
            .find(ViewType.TextField.self)
            .setInput("http://gpu-box:8080/v1")

        XCTAssertEqual(settings.openAIEndpoint, "http://gpu-box:8080/v1")
    }

    func testOpenAIModelFieldWritesBackToSettings() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        XCTAssertNotEqual(settings.openAIModel, "qwen3-32b", "precondition: the input must differ from the stored value")

        try OutputSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIModelField)
            .find(ViewType.TextField.self)
            .setInput("qwen3-32b")

        XCTAssertEqual(settings.openAIModel, "qwen3-32b")
    }

    // MARK: - OpenAI Advanced group

    private func tapAdvanced(_ section: OpenAIConnectionSection) throws {
        try section.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIAdvancedToggle)
            .find(ViewType.Button.self)
            .tap()
    }

    func testAdvancedButtonOpensAndClosesTheGroup() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        let advanced = OpenAIAdvancedDisclosure()
        let section = connectionSection(settings, advanced: advanced)

        try tapAdvanced(section)
        XCTAssertTrue(advanced.isOpen)
        XCTAssertTrue(advanced.scrollPending, "opening asks for the new rows to scroll into view")
        XCTAssertNoThrow(try section.inspect().find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker))

        try tapAdvanced(section)
        XCTAssertFalse(advanced.isOpen)
        XCTAssertThrowsError(try section.inspect().find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker))
    }

    func testFixingAnInvalidHeaderNameKeepsAdvancedOpen() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = ""
        let section = connectionSection(settings, advanced: OpenAIAdvancedDisclosure())

        try section.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameField)
            .find(ViewType.TextField.self)
            .setInput("x")

        XCTAssertNoThrow(try section.inspect().find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameField))
    }

    func testSwitchingAwayFromAnInvalidCustomHeaderKeepsAdvancedOpen() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "Host"
        let section = connectionSection(settings, advanced: OpenAIAdvancedDisclosure())

        try section.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker)
            .find(ViewType.Picker.self)
            .select(value: OpenAIAPIKeyPlacement.bearerToken)

        XCTAssertNoThrow(try section.inspect().find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker))
    }

    func testClickingAdvancedWhileTheHeaderNameIsInvalidKeepsItOpenOnceFixed() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "Content-Type"
        let advanced = OpenAIAdvancedDisclosure()
        let section = connectionSection(settings, advanced: advanced)

        try tapAdvanced(section)
        settings.openAIAPIKeyHeaderName = "x-api-key"

        XCTAssertNoThrow(try section.inspect().find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameField))
        XCTAssertFalse(advanced.scrollPending, "the group was already in view, so nothing scrolls")
    }

    /// Hosted in a real window, since the scroll drives AppKit, which
    /// ViewInspector does not lay out. The window is short enough that the
    /// opened rows land below the fold.
    func testOpeningAdvancedScrollsItsRowsIntoView() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        let advanced = OpenAIAdvancedDisclosure()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: Form {
            connectionSection(settings, advanced: advanced)
        }.formStyle(.grouped))
        window.orderFront(nil)

        let content = try XCTUnwrap(window.contentView)
        var scrollView: NSScrollView?
        pump { scrollView = content.descendants(of: NSScrollView.self).first; return scrollView != nil }
        let clip = try XCTUnwrap(scrollView, "the grouped Form hosts no NSScrollView").contentView
        pump(timeout: 0.3) { false }
        let before = clip.bounds.origin.y

        advanced.toggle(headerNameInvalid: false)
        pump(timeout: 2) { clip.bounds.origin.y != before }

        XCTAssertNotEqual(clip.bounds.origin.y, before, "opening Advanced should scroll its last row into view")
        XCTAssertFalse(advanced.scrollPending, "a handled scroll does not run again")
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OpenAIConnectionSectionTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        guard let defaults = DefaultsSuite.open(suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        return defaults
    }
}

/// The connection section, with Advanced open unless `advanced` says otherwise.
@MainActor
func connectionSection(_ settings: AppSettings, advanced: OpenAIAdvancedDisclosure? = nil) -> OpenAIConnectionSection {
    OpenAIConnectionSection(
        settings: settings,
        apiKeyDrafts: ProtocolAPIKeyDrafts(settings: settings),
        advanced: advanced ?? OpenAIAdvancedDisclosure(isOpen: true),
    )
}
