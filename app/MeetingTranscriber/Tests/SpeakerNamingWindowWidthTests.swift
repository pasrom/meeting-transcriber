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

    /// The pending-meeting picker sits above the dialog, outside its width
    /// bounds, so it has to stay narrow by itself: as a segmented control it
    /// was as wide as all the waiting meetings' titles together.
    func testManyWaitingMeetingsDoNotWidenTheWindowPastItsMaximum() {
        let titles = (1 ... 15).map { "Weekly project sync with the whole team, part \($0)" }
        XCTAssertLessThanOrEqual(windowWidth(waitingMeetings: titles), SpeakerNamingView.maxWidth)
    }

    /// A menu sizes to its widest item, and titles have no length limit: an
    /// import takes the file's basename, a sidecar its `title`.
    func testOneVeryLongMeetingTitleDoesNotWidenTheWindowPastItsMaximum() {
        let long = String(repeating: "Quarterly planning review across all regional teams ", count: 6)
        XCTAssertLessThanOrEqual(windowWidth(waitingMeetings: [long, "Standup"]), SpeakerNamingView.maxWidth)
    }

    /// The naming window's content as `MeetingTranscriberApp` lays it out: the
    /// job picker above the dialog.
    private func windowWidth(waitingMeetings titles: [String]) -> CGFloat {
        let jobs = titles.map { title in
            PipelineJob(meetingTitle: title, appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        }
        let content = VStack(spacing: 0) {
            NamingJobPicker(jobs: jobs, selection: .constant(jobs[0].id))
                .padding(.horizontal)
                .padding(.top, 8)
            SpeakerNamingView(
                data: makeData(participants: ["Ann", "Bob"]), knownSpeakerNames: [], gracePeriod: 0,
            ) { _ in }
        }
        return NSHostingView(rootView: content).fittingSize.width
    }

    /// A short list still opens at the usual width rather than collapsing.
    func testAFewParticipantsKeepTheMinimumWidth() {
        XCTAssertGreaterThanOrEqual(idealWidth(participants: ["Ann", "Bob"]), SpeakerNamingView.minWidth)
    }
}
