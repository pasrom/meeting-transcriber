import Foundation
@testable import MeetingTranscriber
import XCTest

/// `AppSettings.outputDirectoryResolution`: where output goes and why. In its
/// own file because `AppSettingsTests` sits at the 600-line cap; same per-test
/// defaults suite and Keychain account so `--parallel` runs never share state.
///
/// The default folder is injected and points into a temp directory: the
/// production default is `~/Downloads/MeetingTranscriber`, and a test that
/// resolves to it is one step from writing there.
final class AppSettingsOutputDirectoryTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiKeyAccount: String!
    private var fallbackDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AppSettingsOutputDirectoryTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "AppSettingsOutputDirectoryTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        fallbackDir = try makeTempDirectory(prefix: "OutputDirFallback")
        settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount, defaultOutputDir: fallbackDir)
    }

    override func tearDown() {
        settings = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        KeychainHelper.delete(key: apiKeyAccount)
        apiKeyAccount = nil
        super.tearDown()
    }

    func testResolvesToTheDefaultLocationWhenNoFolderIsChosen() {
        XCTAssertEqual(settings.outputDirectoryResolution, .defaultLocation(fallbackDir))
        XCTAssertEqual(settings.effectiveOutputDir, fallbackDir)
        XCTAssertNil(settings.customOutputDir)
    }

    func testResolvesToTheChosenFolderWhileItExists() throws {
        let chosen = try makeTempDirectory(prefix: "ChosenOutputDir")
        settings.setCustomOutputDir(chosen)

        guard case let .custom(url) = settings.outputDirectoryResolution else {
            XCTFail("expected .custom, got \(settings.outputDirectoryResolution)")
            return
        }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, chosen.resolvingSymlinksInPath().path)
        XCTAssertEqual(settings.effectiveOutputDir.resolvingSymlinksInPath().path, chosen.resolvingSymlinksInPath().path)
    }

    /// The reachable case. A deleted folder and an unmounted volume both make
    /// the scoped bookmark throw `NSFileNoSuchFileError`, so deleting the
    /// folder stands in for the unplugged drive an in-process test cannot
    /// produce. The path is read from the bookmark bytes, which outlive the
    /// folder, so the fallback can still name what it is standing in for.
    func testFallsBackToTheDefaultAndNamesTheChosenFolderWhenItIsGone() throws {
        let chosen = try makeTempDirectory(prefix: "ChosenOutputDir")
        settings.setCustomOutputDir(chosen)
        try FileManager.default.removeItem(at: chosen)

        guard case let .fallback(url, configuredPath) = settings.outputDirectoryResolution else {
            XCTFail("expected .fallback, got \(settings.outputDirectoryResolution)")
            return
        }
        XCTAssertEqual(url, fallbackDir)
        // Not `resolvingSymlinksInPath()`: it only strips `/private` from a path
        // that still exists, and this one no longer does.
        XCTAssertEqual(configuredPath.map(Self.withoutPrivatePrefix), Self.withoutPrivatePrefix(chosen.path))
        XCTAssertEqual(settings.effectiveOutputDir, fallbackDir, "a recording is never blocked over a missing folder")
        XCTAssertNil(settings.customOutputDir)
        // The choice itself is kept: the folder may come back.
        XCTAssertNotNil(settings.customOutputDirBookmark)
    }

    /// The temp directory is `/var/folders/...`, a symlink into `/private`;
    /// bookmark bytes record the canonical form.
    private static func withoutPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
