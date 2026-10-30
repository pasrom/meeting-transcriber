@testable import MeetingTranscriber
import XCTest

/// The two recording retention settings: defaults, clamping and persistence,
/// against a throwaway defaults suite.
final class AppSettingsRecordingRetentionTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiKeyAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsRecordingRetentionTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "\(suiteName ?? "")-openAI"
        defaults = DefaultsSuite.open(suiteName)
    }

    override func tearDown() {
        DefaultsSuite.remove(suiteName)
        KeychainHelper.delete(key: apiKeyAccount)
        defaults = nil
        super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
    }

    /// Off by default, so nothing changes for anyone who does not opt in.
    func testDefaultsToOffAndThirtyDays() {
        let settings = makeSettings()
        XCTAssertFalse(settings.recordingRetentionEnabled)
        XCTAssertEqual(settings.recordingRetentionDays, 30)
    }

    func testDaysAreClampedToZero() {
        let settings = makeSettings()
        settings.recordingRetentionDays = -3
        XCTAssertEqual(settings.recordingRetentionDays, 0)
    }

    /// A negative count written outside the app reads as zero too.
    func testAStoredNegativeCountReadsAsZero() {
        defaults.set(-3, forKey: "recordingRetentionDays")
        XCTAssertEqual(makeSettings().recordingRetentionDays, 0)
    }

    func testBothPersistAcrossInstances() {
        let settings = makeSettings()
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 7

        let reloaded = makeSettings()
        XCTAssertTrue(reloaded.recordingRetentionEnabled)
        XCTAssertEqual(reloaded.recordingRetentionDays, 7)
    }
}
