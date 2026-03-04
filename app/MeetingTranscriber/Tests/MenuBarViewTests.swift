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
}
