import Foundation
@testable import MeetingTranscriber
import XCTest

/// `OutputDirectoryResolver`: the destination a recording gets, and the one
/// notification per unavailability episode that goes with a fallback.
///
/// The default folder is injected into a temp directory for the same reason as
/// in `AppSettingsOutputDirectoryTests`: the production default is the user's
/// real Downloads folder.
@MainActor
final class OutputDirectoryResolverTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiKeyAccount: String!
    private var fallbackDir: URL!
    private var notifier: RecordingNotifier!
    private var resolver: OutputDirectoryResolver!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OutputDirectoryResolverTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "OutputDirectoryResolverTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        fallbackDir = try makeTempDirectory(prefix: "OutputDirFallback")
        settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount, defaultOutputDir: fallbackDir)
        notifier = RecordingNotifier()
        resolver = OutputDirectoryResolver(settings: settings, notifier: notifier)
    }

    override func tearDown() async throws {
        resolver = nil
        settings = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        KeychainHelper.delete(key: apiKeyAccount)
        apiKeyAccount = nil
        try await super.tearDown()
    }

    /// A chosen folder that is gone: the default is used, and the user hears
    /// about it once, not once per decision.
    func testAFolderThatCannotBeReachedIsReportedOnceAndTheDefaultIsUsed() throws {
        let chosen = try makeTempDirectory(prefix: "ChosenOutputDir")
        settings.setCustomOutputDir(chosen)
        try FileManager.default.removeItem(at: chosen)

        let first = resolver.resolve()
        let second = resolver.resolve()
        let third = resolver.resolve()

        XCTAssertEqual([first, second, third], [fallbackDir, fallbackDir, fallbackDir])
        XCTAssertEqual(notifier.calls.count, 1, "one episode, one notification: \(notifier.calls.map(\.title))")
        let call = try XCTUnwrap(notifier.calls.first)
        XCTAssertEqual(call.title, OutputDirectoryResolver.unavailableTitle)
        XCTAssertTrue(
            call.body.contains(chosen.resolvingSymlinksInPath().path),
            "the notification names the folder it is standing in for: \(call.body)",
        )
        XCTAssertTrue(call.body.contains(fallbackDir.path), "and where output goes instead: \(call.body)")
        XCTAssertEqual(call.urgency, .standard, "nothing is lost, so nothing breaks through Focus")
    }

    /// A user who never chose a folder gets the default and hears nothing.
    func testNothingIsReportedWhenNoFolderWasChosen() {
        XCTAssertEqual(resolver.resolve(), fallbackDir)
        XCTAssertEqual(resolver.resolve(), fallbackDir)
        XCTAssertTrue(notifier.calls.isEmpty, "\(notifier.calls.map(\.title))")
    }

    func testNothingIsReportedWhileTheChosenFolderResolves() throws {
        let chosen = try makeTempDirectory(prefix: "ChosenOutputDir")
        settings.setCustomOutputDir(chosen)

        XCTAssertEqual(resolver.resolve().resolvingSymlinksInPath().path, chosen.resolvingSymlinksInPath().path)
        XCTAssertTrue(notifier.calls.isEmpty, "\(notifier.calls.map(\.title))")
    }

    /// Recovery ends the episode: a folder that comes back and goes away again
    /// is reported again, the way `PermissionsController` re-notifies after a
    /// recovery. Re-creating the folder at its old path is enough for the
    /// bookmark to resolve again (it falls back to the recorded path).
    func testAFolderThatComesBackAndGoesAgainIsReportedAgain() throws {
        let chosen = try makeTempDirectory(prefix: "ChosenOutputDir")
        settings.setCustomOutputDir(chosen)
        try FileManager.default.removeItem(at: chosen)
        _ = resolver.resolve()
        XCTAssertEqual(notifier.calls.count, 1, "precondition")

        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        XCTAssertEqual(resolver.resolve().resolvingSymlinksInPath().path, chosen.resolvingSymlinksInPath().path)
        XCTAssertEqual(notifier.calls.count, 1, "a folder that is back is not news")

        try FileManager.default.removeItem(at: chosen)
        XCTAssertEqual(resolver.resolve(), fallbackDir)
        XCTAssertEqual(notifier.calls.count, 2, "a new episode is")
    }

    /// Bookmark bytes that cannot be read at all. The path the notification
    /// names comes from the bookmark data, not from the folder, so unreadable
    /// data is the one case that leaves it nil (the same bytes
    /// `RPCSettingsStateTests` uses for the snapshot's null). The user still has
    /// to hear about it, and in a sentence: a body that opens with the missing
    /// path's empty string reads as " cannot be reached right now", which names
    /// nothing and looks like a bug of its own.
    func testABookmarkWhosePathCannotBeReadIsStillReportedInWords() throws {
        settings.customOutputDirBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(
            settings.outputDirectoryResolution,
            .fallback(fallbackDir, configuredPath: nil),
            "precondition: this is the arm with no path to name",
        )

        XCTAssertEqual(resolver.resolve(), fallbackDir)

        XCTAssertEqual(notifier.calls.count, 1, "\(notifier.calls.map(\.title))")
        let call = try XCTUnwrap(notifier.calls.first)
        XCTAssertEqual(call.title, OutputDirectoryResolver.unavailableTitle)
        XCTAssertTrue(
            call.body.hasPrefix("The chosen output folder cannot be reached"),
            "with no path to name, the phrase stands in for it: \(call.body)",
        )
        XCTAssertTrue(call.body.contains(fallbackDir.path), "and where output goes instead: \(call.body)")
    }

    /// Choosing a different folder starts a new episode too: the dedup is per
    /// bookmark, so a second unreachable choice is not hidden behind the first.
    func testChoosingAnotherFolderThatIsAlsoGoneIsReportedAgain() throws {
        let first = try makeTempDirectory(prefix: "ChosenOutputDir")
        settings.setCustomOutputDir(first)
        try FileManager.default.removeItem(at: first)
        _ = resolver.resolve()
        XCTAssertEqual(notifier.calls.count, 1, "precondition")

        let second = try makeTempDirectory(prefix: "ChosenOutputDir")
        settings.setCustomOutputDir(second)
        try FileManager.default.removeItem(at: second)
        _ = resolver.resolve()

        XCTAssertEqual(notifier.calls.count, 2)
        XCTAssertEqual(notifier.calls.last?.body.contains(second.resolvingSymlinksInPath().path), true)
    }
}
