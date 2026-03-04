import ViewInspector
import XCTest

@testable import MeetingTranscriber

final class MenuBarViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeStatus(
        state: TranscriberState = .idle,
        detail: String = "",
        meeting: MeetingInfo? = nil,
        protocolPath: String? = nil,
        error: String? = nil
    ) -> TranscriberStatus {
        TranscriberStatus(
            version: 1,
            timestamp: "2024-01-01T00:00:00",
            state: state,
            detail: detail,
            meeting: meeting,
            protocolPath: protocolPath,
            error: error,
            pid: nil
        )
    }

    private func makeView(
        status: TranscriberStatus? = nil,
        isWatching: Bool = false,
        onNameSpeakers: (() -> Void)? = nil
    ) -> MenuBarView {
        MenuBarView(
            status: status,
            isWatching: isWatching,
            onStartStop: {},
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: onNameSpeakers,
            onQuit: {}
        )
    }

    // MARK: - Start/Stop button

    func testIdleShowsStartWatching() throws {
        let sut = makeView(status: makeStatus(state: .idle), isWatching: false)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Start Watching"))
    }

    func testWatchingShowsStopWatching() throws {
        let sut = makeView(status: makeStatus(state: .watching), isWatching: true)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Watching"))
    }

    // MARK: - Meeting info

    func testMeetingInfoShownWhenRecording() throws {
        let meeting = MeetingInfo(app: "Teams", title: "Standup", pid: 123)
        let sut = makeView(status: makeStatus(state: .recording, meeting: meeting))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Standup"))
    }

    func testMeetingInfoHiddenWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Standup"))
    }

    // MARK: - Error display

    func testErrorShownWhenErrorState() throws {
        let sut = makeView(status: makeStatus(state: .error, error: "Python crashed"))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Python crashed"))
    }

    func testErrorHiddenWhenNotErrorState() throws {
        let sut = makeView(status: makeStatus(state: .recording, error: "stale error"))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "stale error"))
    }

    // MARK: - Name Speakers button

    func testNameSpeakersButtonShownWhenWaiting() throws {
        let sut = makeView(
            status: makeStatus(state: .waitingForSpeakerNames),
            onNameSpeakers: {}
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Name Speakers..."))
    }

    func testNameSpeakersButtonHiddenWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Name Speakers..."))
    }

    // MARK: - Detail text

    func testDetailShownWhenNonEmpty() throws {
        let sut = makeView(status: makeStatus(state: .watching, detail: "Checking Teams..."))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Checking Teams..."))
    }

    func testDetailHiddenWhenEmpty() throws {
        let sut = makeView(status: makeStatus(state: .watching, detail: ""))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Checking Teams..."))
    }

    // MARK: - Protocol link

    func testOpenLastProtocolShownWhenPathPresent() throws {
        let sut = makeView(status: makeStatus(state: .protocolReady, protocolPath: "/tmp/p.md"))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Open Last Protocol"))
    }

    func testOpenLastProtocolHiddenWhenNoPath() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Open Last Protocol"))
    }

    // MARK: - Static buttons always present

    func testSettingsButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Settings..."))
    }

    func testOpenProtocolsFolderButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Open Protocols Folder"))
    }

    func testQuitButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Quit"))
    }

    // MARK: - Button tap callbacks

    func testStartStopButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            onStartStop: { called = true },
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onQuit: {}
        )
        let body = try sut.inspect()
        try body.find(button: "Start Watching").tap()
        XCTAssertTrue(called)
    }

    func testQuitButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            onStartStop: {},
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onQuit: { called = true }
        )
        let body = try sut.inspect()
        try body.find(button: "Quit").tap()
        XCTAssertTrue(called)
    }

    func testSettingsButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            onStartStop: {},
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: { called = true },
            onNameSpeakers: nil,
            onQuit: {}
        )
        let body = try sut.inspect()
        try body.find(button: "Settings...").tap()
        XCTAssertTrue(called)
    }

    func testProtocolsFolderButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            onStartStop: {},
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: { called = true },
            onOpenSettings: {},
            onNameSpeakers: nil,
            onQuit: {}
        )
        let body = try sut.inspect()
        try body.find(button: "Open Protocols Folder").tap()
        XCTAssertTrue(called)
    }

    func testOpenLastProtocolButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .protocolReady, protocolPath: "/tmp/p.md"),
            isWatching: false,
            onStartStop: {},
            onOpenLastProtocol: { called = true },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onQuit: {}
        )
        let body = try sut.inspect()
        try body.find(button: "Open Last Protocol").tap()
        XCTAssertTrue(called)
    }

    func testNameSpeakersButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .waitingForSpeakerNames),
            isWatching: false,
            onStartStop: {},
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: { called = true },
            onQuit: {}
        )
        let body = try sut.inspect()
        try body.find(button: "Name Speakers...").tap()
        XCTAssertTrue(called)
    }

    // MARK: - State label

    func testNilStatusShowsIdleLabel() throws {
        let sut = makeView(status: nil)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Idle"))
    }

    func testMeetingAppAndPidShown() throws {
        let meeting = MeetingInfo(app: "Zoom", title: "Retro", pid: 456)
        let sut = makeView(status: makeStatus(state: .recording, meeting: meeting))
        let body = try sut.inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("Zoom") == true }
        XCTAssertTrue(found, "App name 'Zoom' should appear in meeting info")
    }
}
