@testable import MeetingTranscriber
import XCTest

@MainActor
final class ProtocolOpenerTests: XCTestCase {
    private enum OpenFailure: Error {
        case rejected
    }

    func testNotionPageOpensInRunningDesktopApplication() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.notion.so/page-1"))
        let applicationURL = URL(fileURLWithPath: "/Applications/Notion.app")
        var defaultOpened: [URL] = []
        var desktopOpened: [(page: URL, application: URL)] = []
        let opener = ProtocolOpener(
            runningNotionApplicationURL: { applicationURL },
            openDefault: { defaultOpened.append($0); return true },
            openInApplication: { page, application in
                desktopOpened.append((page, application))
            },
        )

        let succeeded = await opener.open(.notion(pageURL))

        XCTAssertTrue(succeeded)
        XCTAssertEqual(desktopOpened.count, 1)
        XCTAssertEqual(desktopOpened.first?.page, pageURL)
        XCTAssertEqual(desktopOpened.first?.application, applicationURL)
        XCTAssertTrue(defaultOpened.isEmpty)
    }

    func testNotionPageOpensInBrowserWhenDesktopApplicationIsNotRunning() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.notion.so/page-1"))
        var defaultOpened: [URL] = []
        var desktopOpenCount = 0
        let opener = ProtocolOpener(
            runningNotionApplicationURL: { nil },
            openDefault: { defaultOpened.append($0); return true },
            openInApplication: { _, _ in desktopOpenCount += 1 },
        )

        let succeeded = await opener.open(.notion(pageURL))

        XCTAssertTrue(succeeded)
        XCTAssertEqual(defaultOpened, [pageURL])
        XCTAssertEqual(desktopOpenCount, 0)
    }

    func testLocalProtocolAlwaysUsesDefaultOpener() async {
        let fileURL = URL(fileURLWithPath: "/tmp/protocol.md")
        let applicationURL = URL(fileURLWithPath: "/Applications/Notion.app")
        var defaultOpened: [URL] = []
        var desktopOpenCount = 0
        let opener = ProtocolOpener(
            runningNotionApplicationURL: { applicationURL },
            openDefault: { defaultOpened.append($0); return true },
            openInApplication: { _, _ in desktopOpenCount += 1 },
        )

        let succeeded = await opener.open(.file(fileURL))

        XCTAssertTrue(succeeded)
        XCTAssertEqual(defaultOpened, [fileURL])
        XCTAssertEqual(desktopOpenCount, 0)
    }

    func testDesktopOpenFailureFallsBackToOriginalWebURLOnce() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.notion.so/page-1"))
        let applicationURL = URL(fileURLWithPath: "/Applications/Notion.app")
        var defaultOpened: [URL] = []
        var desktopOpenCount = 0
        let opener = ProtocolOpener(
            runningNotionApplicationURL: { applicationURL },
            openDefault: { defaultOpened.append($0); return true },
            openInApplication: { _, _ in
                desktopOpenCount += 1
                throw OpenFailure.rejected
            },
        )

        let succeeded = await opener.open(.notion(pageURL))

        XCTAssertTrue(succeeded)
        XCTAssertEqual(desktopOpenCount, 1)
        XCTAssertEqual(defaultOpened, [pageURL])
    }
}
