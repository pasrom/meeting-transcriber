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
}
