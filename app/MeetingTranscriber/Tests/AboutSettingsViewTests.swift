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
        guard let suite = DefaultsSuite.open(testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(testSuiteName)
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

    func testCheckNowButtonStartsAnUpdateCheck() throws {
        let provider = MockUpdateProvider()
        provider.delay = .seconds(1)
        let checker = UpdateChecker(provider: provider)
        let view = makeAbout(updateChecker: checker)

        try view.inspect().find(button: "Check Now").tap()

        XCTAssertTrue(checker.isChecking)
    }

    private func checkerWithUpdate(installedCask: String?) throws -> UpdateChecker {
        let checker = UpdateChecker(provider: MockUpdateProvider(), installedCask: installedCask)
        checker.availableUpdate = try ReleaseInfo(
            tagName: "v1.0.0",
            name: "Release v1.0.0",
            prerelease: false,
            htmlURL: XCTUnwrap(URL(string: "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0")),
            dmgURL: URL(string: "https://example.com/app.dmg"),
        )
        return checker
    }

    func testHomebrewInstallShowsBrewCommandInsteadOfDownload() throws {
        let body = try makeAbout(updateChecker: checkerWithUpdate(installedCask: "meeting-transcriber")).inspect()
        XCTAssertNoThrow(try body.find(text: "brew update && brew upgrade --cask pasrom/meeting-transcriber/meeting-transcriber"))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.updateCopyBrewCommand))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.updateDownload))
    }

    func testCopyCommandButtonCopiesTheBrewCommand() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AboutSettingsViewTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var view = try makeAbout(updateChecker: checkerWithUpdate(installedCask: "meeting-transcriber"))
        view.pasteboard = pasteboard

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.updateCopyBrewCommand).button().tap()

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "brew update && brew upgrade --cask pasrom/meeting-transcriber/meeting-transcriber",
        )
    }

    func testDMGInstallShowsDownload() throws {
        let body = try makeAbout(updateChecker: checkerWithUpdate(installedCask: nil)).inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.updateDownload))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.updateCopyBrewCommand))
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
