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
    }

    func testApplyPartialMicSetsHypothesisOnlyForMic() {
        let state = LiveCaptionsState()
        state.applyPartial("hello", channel: .mic)
        XCTAssertEqual(state.hypothesisMic, "hello")
        XCTAssertEqual(state.hypothesisApp, "")
        XCTAssertTrue(state.hasContent)
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
        XCTAssertEqual(
            state.recentFinals[0],
            LiveCaptionLine(channel: .mic, text: "you done.", speaker: "Me"),
        )
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

    func testDefaultLabelsMatchPipelineQueue() {
        // "Me" matches PipelineQueue.micLabel's batch default so live and
        // batch transcripts render the same fallback prefix when the live
        // matcher returns nil (no confident match against speakers.json).
        let state = LiveCaptionsState()
        XCTAssertEqual(state.micLabel, "Me")
        XCTAssertEqual(state.appLabel, "Remote")
    }

    func testLabelForChannelLookup() {
        let state = LiveCaptionsState(micLabel: "Mic", appLabel: "Other")
        XCTAssertEqual(state.label(for: .mic), "Mic")
        XCTAssertEqual(state.label(for: .app), "Other")
    }

    func testApplyFinalizedExplicitSpeakerWinsOverDefault() {
        // The matcher-aware path: caller passes the matched name, state
        // captures it per-line — independent of the channel-default label.
        let state = LiveCaptionsState()
        state.applyFinalized("hi there", channel: .app, speaker: "Anna")
        XCTAssertEqual(state.recentFinals.first?.speaker, "Anna")
        XCTAssertEqual(state.recentFinals.first?.channel, .app)
    }

    func testApplyFinalizedConvenienceFallsBackToChannelDefault() {
        // Tests-only convenience: speaker defaults to the channel label.
        // Production wiring always passes an explicit speaker (matched or
        // fallback), but the convenience is used by fixture tests.
        let state = LiveCaptionsState(micLabel: "Me", appLabel: "Remote")
        state.applyFinalized("hello", channel: .mic)
        state.applyFinalized("hi there", channel: .app)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Me", "Remote"])
    }

    // MARK: - Silence deadlines

    func testFadeStartsOnlyAfterTwoSecondsOfSilence() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyPartial("hello", channel: .mic)
        XCTAssertFalse(state.faded)
        await clock.advance(by: .milliseconds(1999))
        XCTAssertFalse(state.faded)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.faded }
        XCTAssertTrue(state.hasContent)
    }

    func testPartialAndFinalEachResetFadeAndRestartHold() async {
        for channel in [LiveCaptionChannel.mic, .app] {
            for finalized in [false, true] {
                let clock = ManualClock()
                let state = LiveCaptionsState(clock: clock)
                state.applyPartial("first", channel: .mic)
                await clock.advance(by: .seconds(2))
                await assertEventually { state.faded }

                if finalized {
                    state.applyFinalized("new final", channel: channel)
                } else {
                    state.applyPartial("new partial", channel: channel)
                }
                XCTAssertFalse(state.faded)
                await clock.advance(by: .milliseconds(1999))
                XCTAssertFalse(state.faded)
                await clock.advance(by: .milliseconds(1))
                await assertEventually { state.faded }
                state.clear()
            }
        }
    }

    func testClearResetsFadeAndCancelsPendingDeadlines() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        state.applyPartial("hello", channel: .mic)
        await clock.advance(by: .seconds(2))
        await assertEventually { state.faded }
        state.clear()
        XCTAssertFalse(state.faded)
        XCTAssertFalse(state.hasContent)

        state.applyPartial("next recording", channel: .app)
        state.clear()
        state.applyFinalized("new caption", channel: .mic)
        await clock.advance(by: .milliseconds(1999))
        XCTAssertFalse(state.faded)
        XCTAssertTrue(state.hasContent)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.faded }
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(state.hasContent, "clear must cancel the prior recording's five-second deadline")
        state.clear()
    }

    func testAutoClearStillOccursAtFiveSeconds() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        state.applyFinalized("hello", channel: .app)
        await clock.advance(by: .seconds(2))
        await assertEventually { state.faded }
        await clock.advance(by: .milliseconds(2999))
        XCTAssertTrue(state.hasContent)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { !state.hasContent }
        XCTAssertFalse(state.faded)
    }

    func testNewEventRestartsAutoClearDeadline() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        state.applyPartial("first", channel: .mic)
        await clock.advance(by: .seconds(2))
        await assertEventually { state.faded }
        state.applyFinalized("new", channel: .app)
        await clock.advance(by: .seconds(2))
        await assertEventually { state.faded }
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(state.hasContent, "the cancelled original five-second deadline must not clear new text")
        await clock.advance(by: .milliseconds(1999))
        XCTAssertTrue(state.hasContent)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { !state.hasContent }
    }

    private func assertEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool,
    ) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    /// The overlay reads its font size from the state, so the window
    /// controller has one place to push a preset change; `.medium` keeps the
    /// bar unchanged until Settings says otherwise.
    func testSizeDefaultsToMediumAndFollowsSetSize() {
        let state = LiveCaptionsState()
        XCTAssertEqual(state.size, .medium)

        state.setSize(.small)

        XCTAssertEqual(state.size, .small)
    }
}
