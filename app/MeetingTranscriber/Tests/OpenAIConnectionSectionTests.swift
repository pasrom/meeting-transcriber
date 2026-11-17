@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Write-back of the Connection Settings fields: each is driven through the
/// view and the stored setting asserted, so a wrong binding fails.
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
