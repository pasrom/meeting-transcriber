@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The About tab (Version, Identifier, Build Date, ffmpeg, GitHub link) plus
/// the Updates section moved into it from General. Split out of
/// `SettingsViewTests` when adding the identifier row took that file past the
/// 600-line cap; the section is self-contained, so it makes a natural seam.
@MainActor
final class AboutSettingsViewTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite — same pattern as the sibling
    /// settings suites. Avoids `swift test --parallel` plist races and keeps a
    /// killed test process from leaking into the dev app's `.standard` plist.
    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "AboutSettingsViewTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    private func makeAbout(
        settings: AppSettings? = nil,
        updateChecker: UpdateChecker? = nil,
    ) -> AboutSettingsView {
        AboutSettingsView(
            settings: settings ?? AppSettings(defaults: defaults),
            updateChecker: updateChecker,
        )
    }

    func testAboutSectionExists() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "Version"))
    }

    func testAboutSectionShowsBuildDate() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "Build Date"))
    }

    /// The identifier decides which settings domain, TCC grants and notification
    /// registration the running app uses, so "which build is this" is not
    /// answerable from the version alone — a dev/release mix-up otherwise shows
    /// up only as permissions or preferences inexplicably missing.
    func testAboutSectionShowsBundleIdentifier() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "Identifier"))
    }

    func testAboutSectionShowsFfmpegStatus() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "ffmpeg"))
    }

    func testAboutSectionShowsGitHubLink() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "GitHub"))
    }

    func testUpdatesSectionShownWhenUpdateCheckerPresent() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeAbout(updateChecker: checker).inspect()
        XCTAssertNoThrow(try body.find(text: "Check for Updates"))
    }

    func testUpdatesSectionHiddenWhenNoChecker() throws {
        let body = try makeAbout().inspect()
        XCTAssertThrowsError(try body.find(text: "Check for Updates"))
    }

    func testPreReleaseToggleShownWhenCheckEnabled() throws {
        let settings = AppSettings(defaults: defaults)
        settings.checkForUpdates = true
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeAbout(settings: settings, updateChecker: checker).inspect()
        XCTAssertNoThrow(try body.find(text: "Include Pre-Releases"))
    }

    func testPreReleaseToggleHiddenWhenCheckDisabled() throws {
        let settings = AppSettings(defaults: defaults)
        settings.checkForUpdates = false
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeAbout(settings: settings, updateChecker: checker).inspect()
        XCTAssertThrowsError(try body.find(text: "Include Pre-Releases"))
    }
}
