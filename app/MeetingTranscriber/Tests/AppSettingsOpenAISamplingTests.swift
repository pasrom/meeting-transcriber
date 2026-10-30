@testable import MeetingTranscriber
import XCTest

/// Persistence and clamping of the optional OpenAI sampling overrides.
final class AppSettingsOpenAISamplingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsOpenAISamplingTests-\(getpid())-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        if let suiteName { DefaultsSuite.remove(suiteName) }
        settings = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testOpenAISamplingOverridesDefaultToUnset() {
        XCTAssertNil(settings.openAITemperature)
        XCTAssertNil(settings.openAITopP)
        XCTAssertNil(defaults.object(forKey: "openAITemperature"))
        XCTAssertNil(defaults.object(forKey: "openAITopP"))
    }

    func testOpenAISamplingOverridesRoundTripThroughDefaults() {
        settings.openAITemperature = 0.4
        settings.openAITopP = 0.85

        let fresh = AppSettings(defaults: defaults)
        XCTAssertEqual(fresh.openAITemperature, 0.4)
        XCTAssertEqual(fresh.openAITopP, 0.85)
    }

    func testClearingAnOpenAISamplingOverrideRemovesTheStoredValue() {
        settings.openAITemperature = 0.4
        settings.openAITemperature = nil

        XCTAssertNil(defaults.object(forKey: "openAITemperature"))
        XCTAssertNil(AppSettings(defaults: defaults).openAITemperature)
    }

    func testOpenAISamplingOverridesAreClampedOnWrite() {
        settings.openAITemperature = 3
        settings.openAITopP = -0.5

        XCTAssertEqual(settings.openAITemperature, 2)
        XCTAssertEqual(settings.openAITopP, 0)
        XCTAssertEqual(defaults.object(forKey: "openAITemperature") as? Double, 2)
    }

    func testOutOfRangeStoredSamplingOverrideIsClampedOnLoad() {
        defaults.set(1.7, forKey: "openAITopP")

        XCTAssertEqual(AppSettings(defaults: defaults).openAITopP, 1)
    }
}
