import XCTest

@testable import MeetingTranscriber

/// Covers the menu-bar failure surface.
///
/// Motivation (2026-08-04): every failure that day was invisible. A missing
/// Accessibility grant, a suppressed browser-consent prompt, and a capture tap
/// that recorded an hour of silence all announced themselves ONLY by
/// notification, and Do Not Disturb suppressed every one. The menu bar is the
/// one surface DND cannot mute, so it must (a) move when the app is broken and
/// (b) never show a calm "recording" badge for a recording capturing nothing.
final class MenuBarBlinkTests: XCTestCase {
    // MARK: - the badge must move when something is wrong

    func testAttentionStatesAnimateSoTheyBlink() {
        XCTAssertTrue(BadgeKind.error.isAnimated, "a broken app must not sit still")
        XCTAssertTrue(BadgeKind.userAction.isAnimated, "a blocked app must not sit still")
    }

    func testCalmStatesDoNotBlink() {
        XCTAssertFalse(BadgeKind.inactive.isAnimated)
        XCTAssertFalse(BadgeKind.done.isAnimated)
        XCTAssertFalse(BadgeKind.updateAvailable.isAnimated, "an update is not an emergency")
    }

    func testBlinkAlternatesAcrossTheCycle() {
        let phases = (0 ..< MenuBarIcon.frameCount).map { MenuBarIcon.blinkIsOn(frame: $0) }
        XCTAssertTrue(phases.contains(true), "overlay must be visible for part of the cycle")
        XCTAssertTrue(phases.contains(false), "overlay must be hidden for part of the cycle")
    }

    func testBlinkPhaseIsStableAcrossCycles() {
        // The frame counter runs forever; the phase must not drift.
        for frame in 0 ..< MenuBarIcon.frameCount {
            XCTAssertEqual(
                MenuBarIcon.blinkIsOn(frame: frame),
                MenuBarIcon.blinkIsOn(frame: frame + MenuBarIcon.frameCount),
            )
        }
    }

    // MARK: - a failing recording must not look healthy

    func testSilentCaptureOutranksTheRecordingBadge() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
            captureProblem: true,
        )
        XCTAssertEqual(badge, .error, "a recording capturing nothing must not show .recording")
    }

    func testHealthyRecordingStillShowsRecording() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
            captureProblem: false,
        )
        XCTAssertEqual(badge, .recording)
    }

    func testPermissionProblemSurfacesWhenIdle() {
        let badge = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
            permissionProblem: true,
        )
        XCTAssertEqual(badge, .error, "a missing permission must not read as Idle")
    }

    func testPermissionProblemOutranksAnAvailableUpdate() {
        let badge = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: true,
            permissionProblem: true,
        )
        XCTAssertEqual(badge, .error)
    }
}
