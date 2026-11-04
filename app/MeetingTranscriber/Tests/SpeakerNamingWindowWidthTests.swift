import AppKit
@testable import MeetingTranscriber
import SwiftUI
import XCTest

/// The naming window is sized to its content, so its width is whatever the
/// content reports as ideal. A chip row has no width to wrap at in that query
/// and reports every chip on one line; with a long participant list that
/// opened the window several screens wide.
@MainActor
final class SpeakerNamingWindowWidthTests: XCTestCase {
    private func makeData(participants: [String]) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "All hands",
            mapping: ["SPEAKER_0": "SPEAKER_0", "SPEAKER_1": "SPEAKER_1"],
            speakingTimes: ["SPEAKER_0": 10, "SPEAKER_1": 5],
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: participants,
            isDualSource: false,
        )
    }

    /// The width the window would open at: the hosted view's ideal size.
    private func idealWidth(participants: [String], known: [String] = []) -> CGFloat {
        let view = SpeakerNamingView(
            data: makeData(participants: participants), knownSpeakerNames: known, gracePeriod: 0,
        ) { _ in }
        return NSHostingView(rootView: view).fittingSize.width
    }

    func testManyParticipantsDoNotWidenTheWindowPastItsMaximum() {
        let participants = (1 ... 60).map { "Participant With A Long Name \($0)" }
        XCTAssertLessThanOrEqual(idealWidth(participants: participants), SpeakerNamingView.maxWidth)
    }

    func testManyKnownNamesDoNotWidenTheWindowPastItsMaximum() {
        let known = (1 ... 60).map { "Known Colleague Number \($0)" }
        XCTAssertLessThanOrEqual(idealWidth(participants: [], known: known), SpeakerNamingView.maxWidth)
    }

    /// A short list still opens at the usual width rather than collapsing.
    func testAFewParticipantsKeepTheMinimumWidth() {
        XCTAssertGreaterThanOrEqual(idealWidth(participants: ["Ann", "Bob"]), SpeakerNamingView.minWidth)
    }
}
