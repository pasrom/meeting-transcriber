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
    func testFinalsPastTheCapLeaveAllButTheNewestTwoAtOnce() {
        let state = LiveCaptionsState()
        let kept = (1 ... 6).map { "line \($0)" }
        for text in kept {
            state.applyFinalized(text, channel: .app)
        }
        XCTAssertEqual(state.recentFinals.map(\.text), kept)

        state.applyFinalized("newest", channel: .mic)
        XCTAssertEqual(state.recentFinals.map(\.text), ["line 6", "newest"])
        XCTAssertEqual(state.recentFinals.map(\.channel), [.app, .mic])
    }

    /// Dropped down to the newest line alone, a short line had no line before it to inherit from.
    func testShortLineAfterTheDropTakesTheSpeakerOfTheLineBeforeIt() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        for index in 1 ... LiveCaptionsState.maxFinalsKept {
            state.applyFinalized("line \(index)", channel: .app, speaker: "Speaker A")
        }
        state.inheritSpeaker(forFinal: state.applyFinalized("terraform", channel: .app))
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker A"])
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
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Remote", "Remote"])

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

    /// A weak slice inside one speaker's turn keeps that speaker when it is also the nearest voice.
    func testUnmatchedLineKeepsThePreviousSpeakerWhenThatIsItsNearestVoice() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let first = state.applyFinalized("we really just wanted", channel: .app, awaitingSpeaker: true)
        state.updateSpeaker("Speaker A", forFinal: first)
        let weak = state.applyFinalized("to go fast", channel: .app, awaitingSpeaker: true)
        state.resolveUnmatched(forFinal: weak, nearest: "Speaker A")
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker A"])
        XCTAssertFalse(state.awaitsSpeaker(lineAt: 1))
    }

    /// Nearest to someone else, or to nobody: the line may be a new voice, so it keeps the channel label.
    func testUnmatchedLineNearestToAnotherVoiceKeepsTheChannelLabel() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("secrets management", channel: .app, speaker: "Speaker A")
        state.resolveUnmatched(forFinal: state.applyFinalized("which turned out", channel: .app), nearest: "Speaker B")
        state.resolveUnmatched(forFinal: state.applyFinalized("to be important", channel: .app), nearest: nil)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Remote", "Remote"])
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

    /// The overlay keeps a short line in the row before it while the line it inherits from awaits its match.
    func testShortLineAwaitsTheMatchOfTheLineItInheritsFrom() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("first", channel: .app, speaker: "Speaker A")
        let pending = state.applyFinalized("pending", channel: .app, awaitingSpeaker: true)
        state.inheritSpeaker(forFinal: state.applyFinalized("short", channel: .app))
        XCTAssertEqual((0 ..< 3).map(state.awaitsSpeaker(lineAt:)), [false, true, true])

        state.updateSpeaker("Speaker A", forFinal: pending)
        XCTAssertEqual((0 ..< 3).map(state.awaitsSpeaker(lineAt:)), [false, false, false])
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
    /// For an expiry that must not happen: a woken expiry task runs on the main actor within milliseconds.
    private func assertStays(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool,
    ) async {
        let deadline = ContinuousClock.now + .milliseconds(200)
        while condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), file: file, line: line)
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

        await settle()
        await clock.advance(by: .seconds(LiveCaptionsState.earlierTurnHold + 1))
        await assertStays { state.recentFinals.map(\.text) == ["first", "second"] }
    }

    /// A line still awaiting its match is no new turn: the turn before it stays.
    func testLineAwaitingItsSpeakerStartsNoTurn() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized("first", channel: .app, speaker: "Speaker A")
        state.applyFinalized("second", channel: .app, awaitingSpeaker: true)
        state.applyPartial("still speaking", channel: .app)

        await settle()
        await clock.advance(by: .seconds(LiveCaptionsState.earlierTurnHold + 1))
        await assertStays { state.recentFinals.map(\.text) == ["first", "second"] }
        XCTAssertTrue(state.awaitsSpeaker(lineAt: 1))
        XCTAssertFalse(state.awaitsSpeaker(lineAt: 0))
    }

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

    func testShortLineDefersEarlierTurnExpiryUntilItsPendingSpeakerMatches() async {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized("first", channel: .app, speaker: "Speaker A")
        let pending = state.applyFinalized("pending", channel: .app, awaitingSpeaker: true)
        state.inheritSpeaker(forFinal: state.applyFinalized("short", channel: .app))

        await clock.advance(by: .seconds(1))
        state.applyPartial("still speaking", channel: .app)
        state.updateSpeaker("Speaker B", forFinal: pending)

        // Require a fresh four-second hold after the match, not an expiry scheduled at append time.
        await waitFor({ await clock.sleepingDeadlines().contains(.seconds(5)) }, timeout: .seconds(1))
        let deadlines = await clock.sleepingDeadlines()
        XCTAssertTrue(deadlines.contains(.seconds(5)))
        await clock.advance(by: .milliseconds(3999))
        XCTAssertEqual(state.recentFinals.map(\.text), ["first", "pending", "short"])
        await clock.advance(by: .milliseconds(1))
        await assertEventually { state.recentFinals.map(\.text) == ["pending", "short"] }
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker B", "Speaker B"])
    }
}
