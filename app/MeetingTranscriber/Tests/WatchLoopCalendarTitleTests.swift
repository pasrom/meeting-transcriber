@testable import MeetingTranscriber
import XCTest

/// A lookup that answers with a fixed meeting and records what it was asked.
private final class StubCalendarLookup: CalendarMeetingLookup {
    var answer: CalendarMeeting?
    var askedStart: Date?
    var askedAppName: String?

    init(answer: CalendarMeeting?) {
        self.answer = answer
    }

    func meeting(startingAt start: Date, appName: String) -> CalendarMeeting? {
        askedStart = start
        askedAppName = appName
        return answer
    }
}

/// How a calendar match reaches the pipeline job. The lookup is consulted once
/// per recording with the recorder's start date, and its answer replaces the
/// window-title fallback only where nothing better is known.
@MainActor
final class WatchLoopCalendarTitleTests: XCTestCase {
    private let fixedStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLoop(
        lookup: StubCalendarLookup,
        queue: PipelineQueue,
        detector: any MeetingDetecting = ImmediatelyInactiveDetector(),
    ) -> (WatchLoop, MockRecorder) {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_calendar_title.wav")
        recorder.recordingStartDate = fixedStart
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            endGracePeriod: 0.01,
            maxDuration: 10,
            noMic: true,
            calendarLookup: lookup,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, recorder)
    }

    private var teamsMeeting: DetectedMeeting {
        DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test Meeting | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 9999,
        )
    }

    func testDetectedMeetingTakesTitleAndAttendeesFromTheCalendar() async throws {
        let lookup = StubCalendarLookup(answer: CalendarMeeting(title: "Weekly sync", attendees: ["Anna", "Ben"]))
        let queue = PipelineQueue()
        let (loop, _) = makeLoop(lookup: lookup, queue: queue)

        try await loop.handleMeeting(teamsMeeting)

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.meetingTitle, "Weekly sync")
        XCTAssertEqual(job.participants, ["Anna", "Ben"], "attendees stand in when the app read no participants")
        XCTAssertEqual(lookup.askedStart, fixedStart, "the recorder's start date is what the event has to cover")
        XCTAssertEqual(lookup.askedAppName, "Microsoft Teams")
    }

    func testWithoutACalendarMatchTheWindowTitleStays() async throws {
        let queue = PipelineQueue()
        let (loop, _) = makeLoop(lookup: StubCalendarLookup(answer: nil), queue: queue)

        try await loop.handleMeeting(teamsMeeting)

        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Test Meeting")
        XCTAssertEqual(queue.jobs.first?.participants, [])
    }

    func testManualRecordingWithTheDefaultTitleIsNamedFromTheCalendar() async throws {
        let queue = PipelineQueue()
        let lookup = StubCalendarLookup(answer: CalendarMeeting(title: "Design review", attendees: []))
        let (loop, _) = makeLoop(lookup: lookup, queue: queue, detector: MeetingDetector(patterns: AppMeetingPattern.all))
        // The app picker passes the app name as the title when the field is left blank.
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Chrome")

        loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Design review")
        XCTAssertEqual(lookup.askedAppName, "Chrome")
    }

    /// A title the user typed is a decision, not a fallback.
    func testManualRecordingKeepsATitleTheUserTyped() async throws {
        let queue = PipelineQueue()
        let lookup = StubCalendarLookup(answer: CalendarMeeting(title: "Design review", attendees: []))
        let (loop, _) = makeLoop(lookup: lookup, queue: queue, detector: MeetingDetector(patterns: AppMeetingPattern.all))
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Notes for the offsite")

        loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Notes for the offsite")
    }

    func testMicrophoneRecordingIsNamedFromTheCalendar() async throws {
        let queue = PipelineQueue()
        let lookup = StubCalendarLookup(answer: CalendarMeeting(title: "Team planning", attendees: ["Cara"]))
        let (loop, _) = makeLoop(lookup: lookup, queue: queue, detector: MeetingDetector(patterns: AppMeetingPattern.all))
        try await loop.startMicrophoneRecording()

        loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Team planning")
        XCTAssertEqual(queue.jobs.first?.participants, ["Cara"])
        XCTAssertEqual(lookup.askedAppName, ManualRecordingInfo.microphoneAppName)
    }
}
