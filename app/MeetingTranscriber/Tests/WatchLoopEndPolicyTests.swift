@testable import MeetingTranscriber
import XCTest

/// Pure-function tests for the decision policy that drives
/// `WatchLoop.waitForMeetingEnd`. These cover each branch without an async
/// timer loop, so the grace-reset / grace-expiry / max-duration interactions
/// are deterministic.
final class WatchLoopEndPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private static let defaultConfig = WatchLoopEndConfig(maxDuration: 100, endGracePeriod: 10)

    private func step(
        meetingActive: Bool,
        elapsedSinceStart: TimeInterval,
        graceStart: Date? = nil,
        config: WatchLoopEndConfig = defaultConfig,
    ) -> WatchLoopEndDecision {
        WatchLoopEndPolicy.step(
            config: config,
            now: t0.addingTimeInterval(elapsedSinceStart),
            startTime: t0,
            graceStart: graceStart,
            meetingActive: meetingActive,
        )
    }

    // MARK: - Max duration

    func testStopsWhenMaxDurationExceeded() {
        XCTAssertEqual(
            step(meetingActive: true, elapsedSinceStart: 100.1),
            .stopMaxDurationExceeded,
        )
    }

    func testMaxDurationTakesPrecedenceOverGrace() {
        // Even with an inactive meeting that would otherwise still be in
        // its grace window, max duration wins.
        XCTAssertEqual(
            step(
                meetingActive: false,
                elapsedSinceStart: 100.5,
                graceStart: t0.addingTimeInterval(100),
            ),
            .stopMaxDurationExceeded,
        )
    }

    // MARK: - Active meeting clears grace

    func testActiveMeetingClearsGrace() {
        XCTAssertEqual(
            step(
                meetingActive: true,
                elapsedSinceStart: 5,
                graceStart: t0.addingTimeInterval(2),
            ),
            .continuePolling(graceStart: nil),
        )
    }

    func testActiveMeetingContinuesWithoutGrace() {
        XCTAssertEqual(
            step(meetingActive: true, elapsedSinceStart: 5, graceStart: nil),
            .continuePolling(graceStart: nil),
        )
    }

    // MARK: - Inactive meeting starts grace

    func testInactiveMeetingStartsGraceWhenNoneRunning() {
        let now = t0.addingTimeInterval(5)
        XCTAssertEqual(
            WatchLoopEndPolicy.step(
                config: Self.defaultConfig,
                now: now,
                startTime: t0,
                graceStart: nil,
                meetingActive: false,
            ),
            .continuePolling(graceStart: now),
        )
    }

    // MARK: - Grace expiry

    func testInactiveMeetingStaysInGraceWhenNotYetExpired() {
        let graceStart = t0.addingTimeInterval(5)
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 9, graceStart: graceStart),
            .continuePolling(graceStart: graceStart),
        )
    }

    func testInactiveMeetingStopsWhenGraceExpired() {
        let graceStart = t0.addingTimeInterval(5)
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 15.5, graceStart: graceStart),
            .stopGraceExpired,
        )
    }

    func testGraceExpiryUsesGreaterThanOrEqual() {
        // Edge case: elapsed since graceStart == endGracePeriod exactly.
        // Current production behaviour treats this as expired (>= comparison).
        let graceStart = t0.addingTimeInterval(0)
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 10, graceStart: graceStart),
            .stopGraceExpired,
        )
    }

    // MARK: - Reset behaviour

    func testGraceResetsWhenMeetingResumesThenEnds() {
        // Sequence reproducing the WatchLoop characterization test on the
        // pure policy: inactive (grace starts) → active (grace clears) →
        // inactive (fresh grace) → inactive past gracePeriod (stops).
        var graceStart: Date?

        // t=1: inactive, grace starts.
        graceStart = expectContinue(step(
            meetingActive: false, elapsedSinceStart: 1, graceStart: graceStart,
        ))
        XCTAssertEqual(graceStart, t0.addingTimeInterval(1))

        // t=2: active, grace clears.
        graceStart = expectContinue(step(
            meetingActive: true, elapsedSinceStart: 2, graceStart: graceStart,
        ))
        XCTAssertNil(graceStart)

        // t=3: inactive, fresh grace.
        graceStart = expectContinue(step(
            meetingActive: false, elapsedSinceStart: 3, graceStart: graceStart,
        ))
        XCTAssertEqual(graceStart, t0.addingTimeInterval(3))

        // t=13: elapsed since fresh grace = 10, threshold met → stop.
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 13, graceStart: graceStart),
            .stopGraceExpired,
        )

        // Critical: the first grace started at t=1, so a monotonic timer
        // would have stopped at t=11. The fact that we are still polling
        // at t=13 proves the reset.
    }

    /// Helper: assert decision is `.continuePolling` and return the new
    /// grace-start carried forward to the next poll.
    private func expectContinue(_ decision: WatchLoopEndDecision) -> Date? {
        guard case let .continuePolling(g) = decision else {
            XCTFail("Expected .continuePolling, got \(decision)")
            return nil
        }
        return g
    }
}
