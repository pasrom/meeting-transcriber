@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class AppPickerViewTests: XCTestCase {
    private struct MockAppsProvider: RunningAppsProvider {
        let apps: [RunningApp]

        func runningApps() -> [RunningApp] {
            apps
        }
    }

    private let testApps = [
        RunningApp(id: 100, name: "Chrome", bundleIdentifier: "com.google.Chrome", icon: nil),
        RunningApp(id: 200, name: "Safari", bundleIdentifier: "com.apple.Safari", icon: nil),
    ]

    // MARK: - Buttons

    func testStartButtonExists() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Start Recording"))
    }

    func testStartButtonDisabledWithoutSelection() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        let button = try body.find(button: "Start Recording")
        XCTAssertTrue(try button.isDisabled())
    }

    func testCancelButtonExists() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Cancel"))
    }

    func testCancelCallsCallback() throws {
        var called = false
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            onStartRecording: { _, _, _ in },
            onCancel: { called = true },
        )
        let body = try sut.inspect()
        try body.find(button: "Cancel").tap()
        XCTAssertTrue(called)
    }

    // MARK: - Header

    func testHeaderShown() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Record App"))
    }

    // MARK: - Meeting Title TextField

    func testMeetingTitlePlaceholderExists() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        // TextField has placeholder "Meeting title (optional)"
        XCTAssertNoThrow(try body.find(ViewType.TextField.self))
    }

    // MARK: - Refresh button

    func testRefreshButtonExists() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        let images = body.findAll(ViewType.Image.self)
        let hasRefreshIcon = images.contains { (try? $0.actualImage().name()) == "arrow.clockwise" }
        XCTAssertTrue(hasRefreshIcon, "Refresh button should exist in header")
    }

    // MARK: - Empty State

    func testEmptyAppListStillShowsButtons() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: []),
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Start Recording"))
        XCTAssertNoThrow(try body.find(button: "Cancel"))
    }
}
