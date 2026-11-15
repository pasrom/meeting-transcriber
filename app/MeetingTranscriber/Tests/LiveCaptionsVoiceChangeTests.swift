@testable import MeetingTranscriber
import XCTest

/// `LiveCaptionsState` around a voice change heard by `VoiceChangeDetector`.
@MainActor
final class LiveCaptionsVoiceChangeTests: XCTestCase {
    /// After a voice change, the live text and the next line show the voice heard; that line ends
    /// the hint, and its own match decides it. The line cut before the change is the previous voice's.
    func testTheNextLineAfterAVoiceChangeTakesThatVoiceAndEndsTheHint() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let cut = state.applyFinalized("what is the gap", channel: .app, awaitingSpeaker: true)
        state.voiceChanged(to: "Speaker B", channel: .app)
        XCTAssertEqual(state.voiceHint(for: .app), "Speaker B")
        XCTAssertNil(state.voiceHint(for: .mic))
        state.applyFinalized("on the mic", channel: .mic)
        XCTAssertEqual(state.voiceHint(for: .app), "Speaker B", "a line on the other channel is no answer")

        let next = state.applyFinalized("i have no idea", channel: .app, awaitingSpeaker: true)
        XCTAssertNil(state.voiceHint(for: .app))
        state.updateSpeaker("Speaker D", forFinal: cut)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker D", "Me", "Speaker B"])
        state.updateSpeaker("Speaker C", forFinal: next)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker D", "Me", "Speaker C"])
    }

    /// A hint the new voice only answers with short lines, which are never matched, must not keep
    /// labelling the channel's live text after them.
    func testAShortLineEndsTheHintToo() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("so that was console", channel: .app, speaker: "Speaker A")
        state.voiceChanged(to: "Speaker B", channel: .app)
        state.inheritSpeaker(forFinal: state.applyFinalized("yeah", channel: .app))
        XCTAssertNil(state.voiceHint(for: .app))
    }

    /// A short line under the detector's voice takes the outcome of the next match on its channel:
    /// matched to no one, the voice may be a guest who is not enrolled, so it falls back to the label.
    func testShortLineAfterAVoiceChangeFollowsTheNextMatch() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("so that was console", channel: .app, speaker: "Speaker A")
        state.voiceChanged(to: "Speaker B", channel: .app)
        state.inheritSpeaker(forFinal: state.applyFinalized("yeah", channel: .app))
        state.inheritSpeaker(forFinal: state.applyFinalized("right", channel: .app))
        let long = state.applyFinalized("we tried that last week", channel: .app, awaitingSpeaker: true)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker B", "Speaker B", "Remote"])

        state.resolveUnmatched(forFinal: long, nearest: nil)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Remote", "Remote", "Remote"])
    }

    /// `clear()` drops a pending hint: the next recording's first line is not the old voice's.
    func testClearDropsAPendingVoiceHint() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.voiceChanged(to: "Speaker B", channel: .app)
        state.clear()
        XCTAssertNil(state.voiceHint(for: .app))
        state.applyFinalized("hello", channel: .app)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Remote"])
    }

    /// Rejecting a voice hint also clears it from the short lines that inherited that speaker.
    func testUnmatchedLineAndItsShortSuccessorFallBackToTheChannelLabel() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("first", channel: .app, speaker: "Speaker A")
        state.voiceChanged(to: "Speaker B", channel: .app)
        let unmatched = state.applyFinalized("second", channel: .app, awaitingSpeaker: true)
        state.inheritSpeaker(forFinal: state.applyFinalized("short continuation", channel: .app))
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker B", "Speaker B"])

        state.resolveUnmatched(forFinal: unmatched, nearest: "Speaker C")
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Remote", "Remote"])
        XCTAssertNil(state.voiceHint(for: .app))
    }

    /// A line too short to match right after a change belongs to the new voice, not the line before.
    func testShortLineRightAfterAVoiceChangeKeepsTheNewVoice() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("so that was console", channel: .app, speaker: "Speaker A")
        state.voiceChanged(to: "Speaker B", channel: .app)
        state.inheritSpeaker(forFinal: state.applyFinalized("yeah", channel: .app))
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker B"])
    }

    /// A second change before any match leaves the short line under the voice heard when it was
    /// spoken: the next match is the third voice's, not this line's.
    func testASecondVoiceChangeKeepsTheShortLineOfTheVoiceBefore() {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("so that was console", channel: .app, speaker: "Speaker A")
        state.voiceChanged(to: "Speaker B", channel: .app)
        state.inheritSpeaker(forFinal: state.applyFinalized("yeah", channel: .app))
        state.voiceChanged(to: "Speaker A", channel: .app)
        let long = state.applyFinalized("we tried that last week", channel: .app, awaitingSpeaker: true)
        state.updateSpeaker("Speaker A", forFinal: long)
        XCTAssertEqual(state.recentFinals.map(\.speaker), ["Speaker A", "Speaker B", "Speaker A"])
    }
}
