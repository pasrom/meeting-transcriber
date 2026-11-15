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

    func testDetectingLanguageKeepsEmptyOverlayVisibleUntilDecisionOrReset() {
        let state = LiveCaptionsState()

        state.setDetectingLanguage(true)

        XCTAssertTrue(state.isDetectingLanguage)
        XCTAssertTrue(state.hasContent)
        XCTAssertFalse(state.faded)
        XCTAssertTrue(state.recentFinals.isEmpty)
        XCTAssertEqual(state.hypothesisMic, "")
        XCTAssertEqual(state.hypothesisApp, "")

        state.setDetectingLanguage(false)
        XCTAssertFalse(state.hasContent)

        state.setDetectingLanguage(true)
        state.clear()
        XCTAssertFalse(state.isDetectingLanguage)
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

    /// The overlay joins lines into rows; dropping one line at a time re-wrapped a row on every line.
    func testFinalsPastTheCapLeaveAllButTheNewestAtOnce() {
        let state = LiveCaptionsState()
        let kept = (1 ... 6).map { "line \($0)" }
        for text in kept {
            state.applyFinalized(text, channel: .app)
        }
        XCTAssertEqual(state.recentFinals.map(\.text), kept)

        state.applyFinalized("newest", channel: .mic)
        XCTAssertEqual(state.recentFinals.map(\.text), ["newest"])
        XCTAssertEqual(state.recentFinals.map(\.channel), [.mic])
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

    func testLateSpeakerMatchUpdatesOnlyItsRetainedFinal() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let first = state.applyFinalized("first", channel: .app)
        let second = state.applyFinalized("second", channel: .app)
        state.applyPartial("newest words", channel: .app)

        state.updateSpeaker("Bob", forFinal: second)
        state.updateSpeaker("Alice", forFinal: first)

        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Alice", "Bob"])
        XCTAssertEqual(state.recentFinals.map(\.text), ["first", "second"])
        XCTAssertEqual(state.hypothesisApp, "newest words")
    }

    func testSpeakerMatchCannotRelabelEvictedOrClearedFinal() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let evicted = state.applyFinalized("same words", channel: .app)
        for _ in 1 ..< LiveCaptionsState.maxFinalsKept {
            state.applyFinalized("middle", channel: .app)
        }
        let cleared = state.applyFinalized("same words", channel: .app)
        state.updateSpeaker("old speaker", forFinal: evicted)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Remote"])

        state.clear()
        let fresh = state.applyFinalized("same words", channel: .app)
        state.updateSpeaker("old speaker", forFinal: cleared)
        state.updateSpeaker("fresh speaker", forFinal: fresh)
        XCTAssertEqual(state.recentFinals.first?.speaker, "fresh speaker")
    }

    func testSpeakerMatchDoesNotRestartReadingHoldOrFade() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        let token = state.applyFinalized("hello", channel: .app)
        await clock.advance(by: .seconds(4))
        await assertEventually { state.faded }
        state.updateSpeaker("Alice", forFinal: token)
        XCTAssertEqual(state.recentFinals.first?.speaker, "Alice")
        XCTAssertTrue(state.faded)
        await clock.advance(by: .seconds(2))
        await assertEventually { !state.hasContent }
    }

    /// A line appended under the channel label and then matched to the running speaker is no new turn.
    func testRelabelIntoTheRunningTurnKeepsItsEarlierLines() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized("first", channel: .app, speaker: "Speaker A")
        let next = state.applyFinalized("second", channel: .app)
        state.updateSpeaker("Speaker A", forFinal: next)
        state.applyPartial("still speaking", channel: .app)

        await clock.advance(by: .seconds(LiveCaptionsState.earlierTurnHold + 1))
        await Task.yield()
        XCTAssertEqual(state.recentFinals.map(\.text), ["first", "second"])
    }

    /// A split leaves the end of a sentence as a line too short to match; it is the same speaker's.
    func testShortLineTakesTheSpeakerOfTheLineBeforeIt() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let first = state.applyFinalized("so that was console then", channel: .app)
        state.updateSpeaker("Speaker A", forFinal: first)
        state.inheritSpeaker(forFinal: state.applyFinalized("terraform", channel: .app))
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker A"])
    }

    /// The match of the line before usually lands after the short line has arrived.
    func testShortLinesFollowAMatchThatLandsAfterThem() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let first = state.applyFinalized("so that was console then", channel: .app)
        state.inheritSpeaker(forFinal: state.applyFinalized("terraform", channel: .app))
        state.inheritSpeaker(forFinal: state.applyFinalized("yes", channel: .app))
        state.applyFinalized("a matched line of its own", channel: .app)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Remote", "Remote", "Remote", "Remote"])

        state.updateSpeaker("Speaker A", forFinal: first)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker A", "Speaker A", "Remote"])
    }

    func testShortLineDoesNotInheritAcrossChannels() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let app = state.applyFinalized("a remote sentence", channel: .app)
        state.updateSpeaker("Speaker A", forFinal: app)
        state.inheritSpeaker(forFinal: state.applyFinalized("okay", channel: .mic))
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Me"])
    }

    // MARK: - Silence deadlines

    func testFinalReadingHoldHasFourSecondFloor() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized("hello", channel: .mic)
        await clock.advance(by: .milliseconds(3999))
        await settle()
        XCTAssertFalse(state.faded)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.faded }
        XCTAssertTrue(state.hasContent)
    }

    func testFinalReadingHoldScalesWithWordCount() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized(Array(repeating: "word", count: 20).joined(separator: " "), channel: .app)
        await clock.advance(by: .milliseconds(5999))
        await settle()
        XCTAssertFalse(state.faded)
        XCTAssertTrue(state.hasContent)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.faded }
    }

    /// A 104-word EOU final measured live held the bar 31 s; two lines show only about 20 words.
    func testFinalReadingHoldIsCappedAtSixSeconds() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized(Array(repeating: "word", count: 104).joined(separator: " "), channel: .app)
        await clock.advance(by: .milliseconds(5999))
        await settle()
        XCTAssertFalse(state.faded)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.faded }
    }

    func testUpdatingHypothesisOnEitherChannelHoldsFade() async {
        for channel in [LiveCaptionChannel.mic, .app] {
            let clock = ManualClock()
            let state = LiveCaptionsState(clock: clock)
            defer { state.clear() }
            state.applyFinalized("finished", channel: channel == .mic ? .app : .mic)
            for step in 1 ... 10 {
                state.applyPartial("still speaking \(step)", channel: channel)
                await clock.advance(by: .milliseconds(4500))
                await settle()
                XCTAssertFalse(state.faded)
            }
            XCTAssertTrue(state.hasContent)
        }
    }

    /// A backend can drop a final without an event, so a hypothesis that
    /// stops updating must not keep the bar up for the rest of the recording.
    func testHypothesisWithoutUpdateIsAbandonedThenFadesAndClears() async {
        for (channel, withFinal) in [(LiveCaptionChannel.mic, true), (.app, true), (.mic, false)] {
            let clock = ManualClock()
            let state = LiveCaptionsState(clock: clock)
            defer { state.clear() }
            if withFinal {
                state.applyFinalized("finished", channel: channel == .mic ? .app : .mic)
            }
            state.applyPartial("dropped", channel: channel)
            await clock.advance(by: .milliseconds(4999))
            await settle()
            XCTAssertFalse(state.faded)
            await clock.advance(by: .milliseconds(1))
            await assertEventually { state.faded }
            await clock.advance(by: .seconds(2))
            await assertEventually { !state.hasContent }
            XCTAssertEqual(state.hypothesisMic + state.hypothesisApp, "")
        }
    }

    func testHypothesisHoldDoesNotShortenALongReadingHold() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized(Array(repeating: "word", count: 20).joined(separator: " "), channel: .app)
        state.applyPartial("dropped", channel: .mic)
        await clock.advance(by: .milliseconds(5999))
        await settle()
        XCTAssertFalse(state.faded)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.faded }
    }

    func testPartialAndFinalEachRestoreOpacity() async {
        for channel in [LiveCaptionChannel.mic, .app] {
            for finalized in [false, true] {
                let clock = ManualClock()
                let state = LiveCaptionsState(clock: clock)
                state.applyFinalized("first", channel: .mic)
                await clock.advance(by: .seconds(4))
                await assertEventually { state.faded }

                if finalized {
                    state.applyFinalized("new final", channel: channel)
                } else {
                    state.applyPartial("new partial", channel: channel)
                }
                XCTAssertFalse(state.faded)
                if finalized {
                    await clock.advance(by: .milliseconds(3999))
                    await settle()
                    XCTAssertFalse(state.faded)
                }
                XCTAssertTrue(state.hasContent)
                state.clear()
            }
        }
    }

    func testClearResetsFadeAndCancelsPendingDeadlines() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        state.applyFinalized("hello", channel: .mic)
        await clock.advance(by: .seconds(4))
        await assertEventually { state.faded }
        state.clear()
        XCTAssertFalse(state.faded)
        XCTAssertFalse(state.hasContent)

        state.applyPartial("next recording", channel: .app)
        state.clear()
        state.applyFinalized("new caption", channel: .mic)
        await clock.advance(by: .milliseconds(3999))
        await settle()
        XCTAssertFalse(state.faded)
        XCTAssertTrue(state.hasContent)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.faded }
        await clock.advance(by: .seconds(1))
        await settle()
        XCTAssertTrue(state.hasContent, "clear must cancel the prior recording's deadline")
        state.clear()
    }

    func testAutoClearOccursWhenTwoSecondFadeCompletes() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        state.applyFinalized("hello", channel: .app)
        await clock.advance(by: .seconds(4))
        await assertEventually { state.faded }
        await clock.advance(by: .milliseconds(1999))
        await settle()
        XCTAssertTrue(state.hasContent)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { !state.hasContent }
        XCTAssertFalse(state.faded)
    }

    func testNewEventRestartsAutoClearDeadline() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        state.applyFinalized("first", channel: .mic)
        await clock.advance(by: .seconds(4))
        await assertEventually { state.faded }
        state.applyFinalized("new", channel: .app)
        await clock.advance(by: .seconds(4))
        await assertEventually { state.faded }
        XCTAssertTrue(state.hasContent, "the cancelled original deadline must not clear new text")
        await clock.advance(by: .milliseconds(1999))
        await settle()
        XCTAssertTrue(state.hasContent)
        await clock.advance(by: .milliseconds(1))
        await assertEventually { !state.hasContent }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(10))
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

@MainActor
extension LiveCaptionsStateTests {
    /// A finished turn stayed above the next speaker's row until the page turn.
    func testEarlierTurnLeavesAfterItsHoldOnceANewSpeakerStarts() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized("first", channel: .app, speaker: "Speaker A")
        state.applyFinalized("second", channel: .app, speaker: "Speaker A")
        state.applyFinalized("reply", channel: .app, speaker: "Speaker B")
        state.applyPartial("still speaking", channel: .app)

        XCTAssertEqual(LiveCaptionsState.earlierTurnHold, 4.0)
        await clock.advance(by: .milliseconds(3999))
        XCTAssertEqual(state.recentFinals.map(\.text), ["first", "second", "reply"])
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.recentFinals.map(\.text) == ["reply"] }
    }
}
