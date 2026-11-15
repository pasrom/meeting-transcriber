import AppKit
@testable import MeetingTranscriber
import XCTest

@MainActor
final class UpdateInstallRouteTests: XCTestCase {
    private static let dmgLink = "https://github.com/pasrom/meeting-transcriber/releases/download/v1.0.0/app.dmg"
    private static let releasesPage = "https://github.com/pasrom/meeting-transcriber/releases"

    private func release(prerelease: Bool = false, dmg: Bool = true) throws -> ReleaseInfo {
        try ReleaseInfo(
            tagName: prerelease ? "v1.0.0-rc1" : "v1.0.0",
            name: "Release",
            prerelease: prerelease,
            htmlURL: XCTUnwrap(URL(string: "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0")),
            dmgURL: dmg ? URL(string: Self.dmgLink) : nil,
        )
    }

    private let caskApp = UpdateInstallRoute.caskAppPath

    // MARK: - installedCask

    func testInstalledCaskFindsStableUnderAppleSiliconPrefix() {
        let cask = UpdateInstallRoute.installedCask(bundlePath: caskApp) { path in
            path == "/opt/homebrew/Caskroom/meeting-transcriber"
        }
        XCTAssertEqual(cask, "meeting-transcriber")
    }

    func testInstalledCaskFindsBetaUnderIntelPrefix() {
        let cask = UpdateInstallRoute.installedCask(bundlePath: caskApp) { path in
            path == "/usr/local/Caskroom/meeting-transcriber@beta"
        }
        XCTAssertEqual(cask, "meeting-transcriber@beta")
    }

    func testInstalledCaskIsNilWithoutCaskroomEntry() {
        XCTAssertNil(UpdateInstallRoute.installedCask(bundlePath: caskApp) { _ in false })
    }

    /// The Caskroom is machine-wide: a dev build or a second copy on a Mac
    /// that has the cask must not be told to upgrade a different app.
    func testInstalledCaskIsNilWhenRunningBundleIsNotTheCaskApp() {
        XCTAssertNil(UpdateInstallRoute.installedCask(bundlePath: "/Users/dev/.build/MeetingTranscriber-Dev.app") { _ in
            true
        })
    }

    // MARK: - resolve

    func testStableCaskGetsBrewCommandForStableRelease() throws {
        let route = try UpdateInstallRoute.resolve(update: release(), installedCask: "meeting-transcriber")
        XCTAssertEqual(
            route,
            .homebrew(command: "brew update && brew upgrade --cask pasrom/meeting-transcriber/meeting-transcriber"),
        )
    }

    /// The stable cask never carries a pre-release, so brew would report it as
    /// up to date; the DMG is the only way to the release.
    func testStableCaskFallsBackToDownloadForPrerelease() throws {
        let route = try UpdateInstallRoute.resolve(
            update: release(prerelease: true), installedCask: "meeting-transcriber",
        )
        try XCTAssertEqual(route, .download(XCTUnwrap(URL(string: Self.dmgLink))))
    }

    /// The beta cask is carried forward on stable releases too.
    func testBetaCaskGetsBrewCommandForStableAndPrerelease() throws {
        for prerelease in [false, true] {
            let route = try UpdateInstallRoute.resolve(
                update: release(prerelease: prerelease), installedCask: "meeting-transcriber@beta",
            )
            XCTAssertEqual(route, .homebrew(command: "brew update && brew upgrade --cask pasrom/meeting-transcriber/meeting-transcriber@beta"))
        }
    }

    func testDMGInstallGetsDownload() throws {
        let route = try UpdateInstallRoute.resolve(update: release(), installedCask: nil)
        try XCTAssertEqual(route, .download(XCTUnwrap(URL(string: Self.dmgLink))))
    }

    func testDownloadFallsBackToReleasePageWithoutDMG() throws {
        let update = try release(dmg: false)
        let route = UpdateInstallRoute.resolve(update: update, installedCask: nil)
        XCTAssertEqual(route, .download(update.htmlURL))
    }

    /// The release JSON decides what gets opened, so a link that is not an
    /// https github.com URL must never reach the workspace.
    func testUntrustedDMGLinkFallsBackToReleasePage() throws {
        let update = try ReleaseInfo(
            tagName: "v1.0.0", name: "Release", prerelease: false,
            htmlURL: XCTUnwrap(URL(string: "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0")),
            dmgURL: URL(string: "https://evil.example/app.dmg"),
        )
        let route = UpdateInstallRoute.resolve(update: update, installedCask: nil)
        XCTAssertEqual(route, .download(update.htmlURL))
    }

    func testUntrustedLinksFallBackToRepositoryReleases() throws {
        let update = try ReleaseInfo(
            tagName: "v1.0.0", name: "Release", prerelease: false,
            htmlURL: XCTUnwrap(URL(string: "file:///Applications/Calculator.app")),
            dmgURL: URL(string: "http://github.com/pasrom/meeting-transcriber/releases/download/v1.0.0/app.dmg"),
        )
        let route = UpdateInstallRoute.resolve(update: update, installedCask: nil)
        try XCTAssertEqual(route, .download(XCTUnwrap(URL(string: Self.releasesPage))))
    }

    // MARK: - isTrustedReleaseURL

    func testTrustedReleaseURLAcceptsGitHubReleaseLinks() throws {
        for link in [
            "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0",
            Self.dmgLink,
            "HTTPS://GitHub.com/pasrom/meeting-transcriber/releases",
        ] {
            try XCTAssertTrue(UpdateInstallRoute.isTrustedReleaseURL(XCTUnwrap(URL(string: link))), link)
        }
    }

    func testTrustedReleaseURLRejectsEverythingElse() throws {
        for link in [
            "http://github.com/pasrom/meeting-transcriber/releases",
            "https://evil.example/app.dmg",
            "https://github.com.evil.example/app.dmg",
            "https://evilgithub.com/app.dmg",
            "https://objects.githubusercontent.com/app.dmg",
            "https://github.com@evil.example/",
            "https://user:pass@github.com/pasrom/meeting-transcriber/releases",
            "https://github.com:8443/pasrom/meeting-transcriber/releases",
            "javascript:alert(1)",
            "file:///Applications/Calculator.app",
            "x-apple.systempreferences:com.apple.preference.security",
        ] {
            try XCTAssertFalse(UpdateInstallRoute.isTrustedReleaseURL(XCTUnwrap(URL(string: link))), link)
        }
    }

    func testReleasesPageIsTrusted() {
        XCTAssertTrue(UpdateInstallRoute.isTrustedReleaseURL(UpdateInstallRoute.releasesPage))
        XCTAssertEqual(UpdateInstallRoute.releasesPage.absoluteString, Self.releasesPage)
    }

    // MARK: - perform

    func testHomebrewRouteCopiesCommand() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UpdateInstallRouteTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        UpdateInstallRoute.homebrew(command: "brew upgrade --cask meeting-transcriber")
            .perform(pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "brew upgrade --cask meeting-transcriber")
    }

    // MARK: - UpdateChecker wiring

    func testCheckerRouteFollowsInstalledCask() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider(), installedCask: "meeting-transcriber")

        XCTAssertEqual(
            try checker.installRoute(for: release()),
            .homebrew(command: "brew update && brew upgrade --cask pasrom/meeting-transcriber/meeting-transcriber"),
        )
    }
}
