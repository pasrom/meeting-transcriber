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

    // MARK: - Opacity fade (pure function of lastEventAt vs passed-in date)

    func testOpacityIsZeroWithoutAnyEvent() {
        let state = LiveCaptionsState()
        XCTAssertEqual(state.opacity(at: Date()), 0.0, accuracy: 0.0001)
    }

    func testOpacityIsFullRightAfterEvent() {
        let state = LiveCaptionsState()
        state.applyPartial("hi", channel: .mic)
        XCTAssertEqual(state.opacity(at: state.lastEventAt), 1.0, accuracy: 0.0001)
    }

    func testOpacityIsFullUntilFadeStartBoundary() {
        let state = LiveCaptionsState()
        state.applyPartial("hi", channel: .mic)
        let justBeforeFade = state.lastEventAt
            .addingTimeInterval(LiveCaptionsState.fadeStartSeconds - 0.01)
        XCTAssertEqual(state.opacity(at: justBeforeFade), 1.0, accuracy: 0.0001)
    }

    func testOpacityIsZeroAtFadeEndBoundary() {
        let state = LiveCaptionsState()
        state.applyPartial("hi", channel: .mic)
        let atFadeEnd = state.lastEventAt
            .addingTimeInterval(LiveCaptionsState.fadeEndSeconds)
        XCTAssertEqual(state.opacity(at: atFadeEnd), 0.0, accuracy: 0.0001)
    }

    func testOpacityInterpolatesLinearlyMidway() {
        let state = LiveCaptionsState()
        state.applyPartial("hi", channel: .mic)
        let mid = (LiveCaptionsState.fadeStartSeconds + LiveCaptionsState.fadeEndSeconds) / 2
        let midpointDate = state.lastEventAt.addingTimeInterval(mid)
        XCTAssertEqual(state.opacity(at: midpointDate), 0.5, accuracy: 0.01)
    }

    func testOpacityStaysZeroBeyondFadeEnd() {
        let state = LiveCaptionsState()
        state.applyPartial("hi", channel: .mic)
        let wayLater = state.lastEventAt
            .addingTimeInterval(LiveCaptionsState.fadeEndSeconds + 10.0)
        XCTAssertEqual(state.opacity(at: wayLater), 0.0, accuracy: 0.0001)
    }
}
