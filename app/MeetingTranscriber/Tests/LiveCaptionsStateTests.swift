@testable import MeetingTranscriber
import XCTest

@MainActor
final class LiveCaptionsStateTests: XCTestCase {
    func testInitialStateIsEmpty() {
        let state = LiveCaptionsState()
        XCTAssertEqual(state.hypothesisMic, "")
        XCTAssertEqual(state.hypothesisApp, "")
        XCTAssertTrue(state.recentFinals.isEmpty)
        XCTAssertFalse(state.hasContent)
        XCTAssertEqual(state.lastEventAt, .distantPast)
    }

    func testApplyPartialMicSetsHypothesisOnlyForMic() {
        let state = LiveCaptionsState()
        state.applyPartial("hello", channel: .mic)
        XCTAssertEqual(state.hypothesisMic, "hello")
        XCTAssertEqual(state.hypothesisApp, "")
        XCTAssertTrue(state.hasContent)
        XCTAssertGreaterThan(state.lastEventAt, .distantPast)
    }

    func testApplyPartialAppSetsHypothesisOnlyForApp() {
        let state = LiveCaptionsState()
        state.applyPartial("from remote", channel: .app)
        XCTAssertEqual(state.hypothesisMic, "")
        XCTAssertEqual(state.hypothesisApp, "from remote")
        XCTAssertTrue(state.hasContent)
    }

    func testApplyPartialOnOneChannelDoesNotClearTheOther() {
        let state = LiveCaptionsState()
        state.applyPartial("you are speaking", channel: .mic)
        state.applyPartial("they are speaking", channel: .app)
        XCTAssertEqual(state.hypothesisMic, "you are speaking")
        XCTAssertEqual(state.hypothesisApp, "they are speaking")
    }

    func testApplyFinalizedClearsThatChannelHypothesisOnly() {
        let state = LiveCaptionsState()
        state.applyPartial("you are speaking", channel: .mic)
        state.applyPartial("they are speaking", channel: .app)
        state.applyFinalized("you done.", channel: .mic)
        XCTAssertEqual(state.hypothesisMic, "")
        XCTAssertEqual(state.hypothesisApp, "they are speaking")
        XCTAssertEqual(state.recentFinals.count, 1)
        XCTAssertEqual(state.recentFinals[0], LiveCaptionLine(channel: .mic, text: "you done."))
    }

    func testFinalsRotationCapDropsOldestFirst() {
        let state = LiveCaptionsState()
        state.applyFinalized("first", channel: .mic)
        state.applyFinalized("second", channel: .app)
        state.applyFinalized("third", channel: .mic)
        // maxFinalsKept = 2 → first must drop
        XCTAssertEqual(state.recentFinals.count, LiveCaptionsState.maxFinalsKept)
        XCTAssertEqual(state.recentFinals.map(\.text), ["second", "third"])
        XCTAssertEqual(state.recentFinals.map(\.channel), [.app, .mic])
    }

    func testClearResetsEverything() {
        let state = LiveCaptionsState()
        state.applyPartial("partial", channel: .mic)
        state.applyFinalized("first", channel: .app)
        state.applyFinalized("second", channel: .mic)
        XCTAssertTrue(state.hasContent)

        state.clear()

        XCTAssertEqual(state.hypothesisMic, "")
        XCTAssertEqual(state.hypothesisApp, "")
        XCTAssertTrue(state.recentFinals.isEmpty)
        XCTAssertFalse(state.hasContent)
        XCTAssertEqual(state.lastEventAt, .distantPast)
    }

    func testHasContentTrueWhenOnlyOneHypothesisSet() {
        let state = LiveCaptionsState()
        state.applyPartial("just mic", channel: .mic)
        XCTAssertTrue(state.hasContent)

        let state2 = LiveCaptionsState()
        state2.applyPartial("just app", channel: .app)
        XCTAssertTrue(state2.hasContent)
    }

    func testHasContentTrueWhenOnlyFinalsPresent() {
        let state = LiveCaptionsState()
        state.applyFinalized("done", channel: .mic)
        XCTAssertTrue(state.hasContent)
    }

    func testChannelLabelStrings() {
        XCTAssertEqual(LiveCaptionChannel.mic.label, "Du")
        XCTAssertEqual(LiveCaptionChannel.app.label, "Remote")
    }
}
