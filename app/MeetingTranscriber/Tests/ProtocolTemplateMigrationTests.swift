@testable import MeetingTranscriber
import XCTest

/// The one-time carry-over of the custom prompt from before templates, against
/// a temp folder and scratch defaults suites standing in for the dev and the
/// release build, which share the folder but not their defaults.
final class ProtocolTemplateMigrationTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var root: URL!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var store: ProtocolTemplateStore!

    private let key = AppSettings.defaultProtocolTemplateKey
    private let legacyText = "My committee prompt in {LANGUAGE}.\n"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeTempDirectory(prefix: "protocol-template-migration")
        store = ProtocolTemplateStore(directory: root.appendingPathComponent("Protocol Templates", isDirectory: true))
    }

    private var legacyPrompt: URL {
        root.appendingPathComponent("protocol_prompt.md")
    }

    private var marker: URL {
        store.directory.appendingPathComponent(ProtocolTemplateMigration.markerFilename)
    }

    /// A fresh defaults domain, standing in for one build's UserDefaults.
    private func makeDefaults() throws -> UserDefaults {
        let name = "ProtocolTemplateMigrationTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        return try XCTUnwrap(DefaultsSuite.open(name))
    }

    private func migrate(_ defaults: UserDefaults) {
        ProtocolTemplateMigration.run(defaults: defaults, legacyPrompt: legacyPrompt, store: store)
    }

    private func markerText() throws -> String {
        try String(contentsOf: marker, encoding: .utf8)
    }

    // MARK: - First launch

    func testWithoutALegacyPromptTheBuiltInIsTheDefault() throws {
        let defaults = try makeDefaults()

        migrate(defaults)

        XCTAssertEqual(defaults.string(forKey: key), "")
        XCTAssertEqual(try markerText(), "")
        XCTAssertEqual(store.names(), [])
        XCTAssertEqual(AppSettings(defaults: defaults).defaultProtocolTemplate, .builtIn)
    }

    func testABlankLegacyPromptIsNotCopied() throws {
        try " \n\t\n".write(to: legacyPrompt, atomically: true, encoding: .utf8)
        let defaults = try makeDefaults()

        migrate(defaults)

        XCTAssertEqual(store.names(), [])
        XCTAssertEqual(defaults.string(forKey: key), "")
    }

    func testTheLegacyPromptBecomesTheDefaultTemplateAndStaysUntouched() throws {
        try legacyText.write(to: legacyPrompt, atomically: true, encoding: .utf8)
        let legacyBytes = try Data(contentsOf: legacyPrompt)
        let defaults = try makeDefaults()

        migrate(defaults)

        XCTAssertEqual(store.names(), ["Custom Prompt"])
        XCTAssertEqual(try Data(contentsOf: store.fileURL(named: "Custom Prompt")), legacyBytes)
        XCTAssertEqual(try markerText(), "Custom Prompt")
        XCTAssertEqual(AppSettings(defaults: defaults).defaultProtocolTemplate, .file(name: "Custom Prompt"))
        XCTAssertEqual(try Data(contentsOf: legacyPrompt), legacyBytes, "the legacy prompt was modified")
    }

    /// Settings may create the folder, and a template in it, before the
    /// migration ever ran; the folder existing must not count as migrated.
    func testAFolderCreatedBeforeTheMigrationStillMigratesUnderAFreeName() throws {
        try legacyText.write(to: legacyPrompt, atomically: true, encoding: .utf8)
        try store.create(name: "custom prompt")
        let defaults = try makeDefaults()

        migrate(defaults)

        XCTAssertEqual(store.names(), ["custom prompt", "Custom Prompt 2"])
        XCTAssertEqual(store.text(for: .file(name: "Custom Prompt 2")), legacyText)
        XCTAssertEqual(defaults.string(forKey: key), "Custom Prompt 2")
    }

    /// The marker records completion: a later launch neither copies the
    /// prompt again nor brings back a template the user deleted.
    func testALaterLaunchCopiesNothingAgain() throws {
        try legacyText.write(to: legacyPrompt, atomically: true, encoding: .utf8)
        let defaults = try makeDefaults()
        migrate(defaults)
        try FileManager.default.removeItem(at: store.fileURL(named: "Custom Prompt"))

        migrate(defaults)

        XCTAssertEqual(store.names(), [])
    }

    // MARK: - Failure and retry

    func testAFailedCopyWritesNoMarkerAndTheNextLaunchMigrates() throws {
        try legacyText.write(to: legacyPrompt, atomically: true, encoding: .utf8)
        let fm = FileManager.default
        let folder = store.directory.path
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Read-only: the folder exists, as Settings would leave it, but the copy cannot be written.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        let defaults = try makeDefaults()

        migrate(defaults)

        XCTAssertFalse(fm.fileExists(atPath: marker.path), "a marker was written although nothing was copied")
        XCTAssertNil(defaults.object(forKey: key), "the failed launch fixed the default at the built-in")
        XCTAssertEqual(AppSettings(defaults: defaults).defaultProtocolTemplate, .builtIn)
        XCTAssertEqual(try String(contentsOf: legacyPrompt, encoding: .utf8), legacyText)

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        migrate(defaults)

        XCTAssertEqual(store.names(), ["Custom Prompt"])
        XCTAssertEqual(defaults.string(forKey: key), "Custom Prompt")
    }

    // MARK: - The other build

    /// The second build finds the marker: it adopts the migrated default
    /// without copying the prompt a second time.
    func testTheOtherBuildTakesTheDefaultFromTheMarker() throws {
        try legacyText.write(to: legacyPrompt, atomically: true, encoding: .utf8)
        try migrate(makeDefaults())
        let otherBuild = try makeDefaults()

        migrate(otherBuild)

        XCTAssertEqual(store.names(), ["Custom Prompt"])
        XCTAssertEqual(otherBuild.string(forKey: key), "Custom Prompt")
    }

    func testTheOtherBuildTakesTheBuiltInWhenTheMigratedFileIsGone() throws {
        try legacyText.write(to: legacyPrompt, atomically: true, encoding: .utf8)
        try migrate(makeDefaults())
        try FileManager.default.removeItem(at: store.fileURL(named: "Custom Prompt"))
        let otherBuild = try makeDefaults()

        migrate(otherBuild)

        XCTAssertEqual(otherBuild.string(forKey: key), "")
    }

    func testADefaultAlreadyChosenIsLeftAlone() throws {
        try legacyText.write(to: legacyPrompt, atomically: true, encoding: .utf8)
        let defaults = try makeDefaults()
        defaults.set("Workshop", forKey: key)

        migrate(defaults)

        XCTAssertEqual(store.names(), ["Custom Prompt"], "the copy itself still happens")
        XCTAssertEqual(defaults.string(forKey: key), "Workshop")
    }
}
