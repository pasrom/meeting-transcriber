@testable import MeetingTranscriber
import XCTest

/// The real opener's lookups. They only ask LaunchServices; nothing here opens a
/// file, reveals one or shows a panel.
@MainActor
final class TemplateOpenerTests: XCTestCase {
    func testAnAppEveryMacHasResolvesByItsBundleIdentifier() throws {
        let textEdit = try XCTUnwrap(TemplateOpener.live.installedApp("com.apple.TextEdit"))

        XCTAssertEqual(textEdit.bundleIdentifier, "com.apple.TextEdit")
        XCTAssertEqual(textEdit.name, "TextEdit")
        XCTAssertEqual(textEdit.url.pathExtension, "app")
    }

    func testAnUnknownBundleIdentifierResolvesToNone() {
        XCTAssertNil(TemplateOpener.live.installedApp("invalid.meetingtranscriber.no-such-app"))
    }

    /// No template file exists anywhere here: the lookups go by the Markdown
    /// content type, not by a file.
    func testTheMarkdownLookupsAnswerWithoutAFile() throws {
        let offered = TemplateOpener.live.markdownApps()

        XCTAssertFalse(offered.isEmpty)
        let defaultApp = try XCTUnwrap(TemplateOpener.live.defaultMarkdownApp())
        XCTAssertTrue(offered.contains { $0.bundleIdentifier == defaultApp.bundleIdentifier })
    }
}
