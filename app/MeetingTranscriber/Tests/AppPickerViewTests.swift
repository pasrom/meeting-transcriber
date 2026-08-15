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
            startWouldBeRefused: false,
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Start Recording"))
    }

    func testStartButtonDisabledWithoutSelection() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            startWouldBeRefused: false,
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        let button = try body.find(button: "Start Recording")
        XCTAssertTrue(button.isDisabled())
    }

    /// Wiring only: the decision itself is covered in `AppPickerStartStateTests`.
    ///
    /// Asserts the explanation rather than `isDisabled()` on purpose. Nothing is
    /// selected here, so the button is disabled either way and that assertion
    /// would pass even with the state unwired: measured, it does. The text is the
    /// one signal that only appears when `startWouldBeRefused` actually
    /// reaches the view. `allowsStart` is covered as a value one layer down, and
    /// the loss itself is prevented by the guard in `WatchingController`, not
    /// here, so an unpinned `.disabled` costs a bad press and not a recording.
    func testStartButtonExplainsARefusedStart() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            startWouldBeRefused: true,
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(
            try body.find(text: "Another recording is already starting or under way. The menu bar shows it once it is running."),
        )
    }

    func testCancelButtonExists() throws {
        let sut = AppPickerView(
            appsProvider: MockAppsProvider(apps: testApps),
            startWouldBeRefused: false,
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
            startWouldBeRefused: false,
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
            startWouldBeRefused: false,
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
            startWouldBeRefused: false,
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
            startWouldBeRefused: false,
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
            startWouldBeRefused: false,
            onStartRecording: { _, _, _ in },
            onCancel: {},
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Start Recording"))
        XCTAssertNoThrow(try body.find(button: "Cancel"))
    }
}
