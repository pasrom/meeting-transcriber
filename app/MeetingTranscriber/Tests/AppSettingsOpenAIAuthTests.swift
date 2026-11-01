@testable import MeetingTranscriber
import XCTest

final class AppSettingsOpenAIAuthTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsOpenAIAuthTests-\(getpid())-\(UUID().uuidString)"
        defaults = DefaultsSuite.open(suiteName)
    }

    override func tearDown() {
        if let suiteName { DefaultsSuite.remove(suiteName) }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAPIKeyPlacementDefaultsToBearerAndPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.openAIAPIKeyPlacement, .bearerToken)
        XCTAssertEqual(settings.openAIAPIKeyHeaderName, "api-key")

        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "x-api-key"
        XCTAssertEqual(defaults.string(forKey: "openAIAPIKeyPlacement"), "customHeader")
        XCTAssertEqual(defaults.string(forKey: "openAIAPIKeyHeaderName"), "x-api-key")

        let fresh = AppSettings(defaults: defaults)
        XCTAssertEqual(fresh.openAIAPIKeyPlacement, .customHeader)
        XCTAssertEqual(fresh.openAIAPIKeyHeaderName, "x-api-key")
    }

    func testAnUnknownStoredPlacementFallsBackToBearer() {
        defaults.set("someFutureMode", forKey: "openAIAPIKeyPlacement")

        XCTAssertEqual(AppSettings(defaults: defaults).openAIAPIKeyPlacement, .bearerToken)
    }
}
