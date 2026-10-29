@testable import MeetingTranscriber
import XCTest

/// Tests for `WatchLoop.waitForMeetingEnd`'s async timing paths. Driven
/// by `TestClock` (in `TestHelpers.swift`) so each `sleep` resolves
/// instantly while advancing the virtual clock — no wall-clock waits,
/// no `Task.sleep`-jitter sensitivity on loaded CI runners.
@MainActor
final class WatchLoopTimingTests: XCTestCase {
    private func makeMeeting() -> DetectedMeeting {
        DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 1234,
        )
    }

    // MARK: - Grace period

    func testWaitForMeetingEndGracePeriod() async throws {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = { [:] }

        let clock = TestClock()
        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        let virtualStart = clock.now
        try await loop.waitForMeetingEnd(makeMeeting())
        let elapsed = clock.now.timeIntervalSince(virtualStart)

        XCTAssertGreaterThanOrEqual(
            elapsed, 0.1, "Should wait at least the grace period (virtual time)",
        )
    }

    // MARK: - Max duration

    func testWaitForMeetingEndMaxDuration() async throws {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = {
            [1234: [["Process Name": "MSTeams", "AssertName": "Microsoft Teams Call in progress"]]]
        }

        let clock = TestClock()
        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            maxDuration: 0.15,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        let virtualStart = clock.now
        try await loop.waitForMeetingEnd(makeMeeting())
        let elapsed = clock.now.timeIntervalSince(virtualStart)

        XCTAssertGreaterThan(
            elapsed, 0.15, "Should wait at least maxDuration (virtual time)",
        )
    }

    // MARK: - Grace reset on meeting resume

    /// Characterization test pinning the grace-reset behaviour: when the
    /// meeting becomes inactive, then resumes, then ends again, the
    /// grace-period timer must restart from scratch — i.e. the second
    /// grace window has to run its full duration independent of the
    /// first, partially elapsed one.
    ///
    /// Driven by `TestClock` so the assertion is deterministic — wall-clock
    /// `Task.sleep` jitter cannot expire the grace window prematurely.
    func testWaitForMeetingEndResetsGraceWhenMeetingResumes() async throws {
        let detector = PowerAssertionDetector()
        let activeAssertions: [Int32: [[String: Any]]] = [
            1234: [["Process Name": "MSTeams", "AssertName": "Microsoft Teams Call in progress"]],
        ]
        // Sequence: inactive, ACTIVE, inactive, inactive, …
        // Without grace-reset the loop returns at poll 3 (graceStart from
        // poll 1 would have ≥ grace elapsed by virtual t=0.10). With reset
        // the loop returns no earlier than poll 5 because poll 2 clears
        // graceStart and the fresh grace started at poll 3 only expires
        // once virtual time advances by another full grace window.
        let callCount = ManagedCounter()
        detector.assertionProvider = {
            let n = callCount.increment()
            return n == 2 ? activeAssertions : [:]
        }

        let clock = TestClock()
        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 30,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        try await loop.waitForMeetingEnd(makeMeeting())

        XCTAssertGreaterThanOrEqual(
            callCount.value, 5,
            "Grace must reset on resume; observed only \(callCount.value) polls — "
                + "without reset the loop would return at poll 3 once the original "
                + "grace window had elapsed.",
        )
    }

    // MARK: - Back-to-back calls (issue #765)

    private static let teamsCall = PowerAssertionFixture.teamsCall

    /// A detector whose assertions follow `timeline` on the virtual clock:
    /// each entry holds from its offset until the next entry's.
    private func timelineDetector(
        _ clock: TestClock,
        _ timeline: [(from: TimeInterval, assertions: [Int32: [[String: Any]]])],
    ) -> PowerAssertionDetector {
        let start = clock.now
        let detector = PowerAssertionDetector()
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            let elapsed = clock.now.timeIntervalSince(start)
            return timeline.last { $0.from <= elapsed }?.assertions ?? [:]
        }
        return detector
    }

    private func timedLoop(
        _ detector: PowerAssertionDetector,
        _ clock: TestClock,
        recorderFactory: @escaping @MainActor () async -> any RecordingProvider = { makeMockRecorder() },
    ) -> WatchLoop {
        WatchLoop(
            detector: detector, recorderFactory: recorderFactory,
            pollInterval: 0.05, endGracePeriod: 0.5, maxDuration: 30,
            nowProvider: { clock.now }, sleepProvider: { await clock.sleep(for: $0) },
        )
    }

    func testWaitForMeetingEndStopsWhenTheAppMovesToANewCallWithinGrace() async throws {
        let clock = TestClock()
        let loop = timedLoop(timelineDetector(clock, [
            (0, Self.teamsCall(1, 2, 1234)),
            (1.0, [:]), // gap shorter than the grace
            (1.2, Self.teamsCall(3, 4, 1234)),
        ]), clock)
        let virtualStart = clock.now

        let reason = try await loop.waitForMeetingEnd(makeMeeting())

        XCTAssertEqual(reason, .replacedByNewCall)
        XCTAssertLessThan(clock.now.timeIntervalSince(virtualStart), 1.5, "must stop when the new call appears")
    }

    func testWaitForMeetingEndKeepsRecordingWhenTheSameCallComesBack() async throws {
        let clock = TestClock()
        let loop = timedLoop(timelineDetector(clock, [
            (0, Self.teamsCall(1, 2, 1234)),
            (1.0, [:]),
            (1.2, Self.teamsCall(1, 2, 1234)),
            (2.0, [:]),
        ]), clock)
        let virtualStart = clock.now

        let reason = try await loop.waitForMeetingEnd(makeMeeting())

        XCTAssertEqual(reason, .ended)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(virtualStart), 2.5)
    }

    /// The whole loop: two back-to-back calls become two recordings, and the
    /// second starts while its call is still running. The detector's cooldown
    /// runs on wall-clock time, so if it were applied after the split the
    /// virtual timeline would race past the second call before detection
    /// resumed, and only one recording would start.
    func testBackToBackCallsBecomeTwoRecordings() async {
        let clock = TestClock()
        let virtualStart = clock.now
        var recorders: [MockRecorder] = []
        var recordingStarts: [TimeInterval] = []
        let loop = timedLoop(timelineDetector(clock, [
            (0, Self.teamsCall(1, 2, 1234)),
            (1.0, [:]),
            (1.2, Self.teamsCall(3, 4, 1234)),
            (3.0, [:]),
        ]), clock) {
            recordingStarts.append(clock.now.timeIntervalSince(virtualStart))
            let recorder = makeMockRecorder()
            recorders.append(recorder)
            return recorder
        }
        loop.permissionChecker = { .allHealthy }

        loop.start()
        // Wall-clock bail-out: a watch task that exits or parks outside
        // clock.sleep would otherwise leave this loop spinning forever.
        let deadline = Date().addingTimeInterval(10)
        while clock.now.timeIntervalSince(virtualStart) < 5, Date() < deadline {
            await Task.yield()
        }
        loop.stop()

        XCTAssertEqual(recorders.count, 2, "each call must get its own recording")
        XCTAssertTrue(recorders.allSatisfy(\.stopCalled))
        if recordingStarts.count == 2 {
            XCTAssertGreaterThan(recordingStarts[1], 1.2)
            // The end poll sees the switch within one poll; re-confirming the
            // call from scratch would add two more.
            XCTAssertLessThan(recordingStarts[1], 1.3, "the second recording must start right after the switch")
        }
    }
}
