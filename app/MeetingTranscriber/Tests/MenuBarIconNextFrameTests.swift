import Combine
@testable import MeetingTranscriber
import XCTest

final class MenuBarIconNextFrameTests: XCTestCase {
    func testStaticBadgesDoNotAdvance() {
        for badge in [BadgeKind.inactive, .userAction, .done, .error, .updateAvailable] {
            XCTAssertEqual(
                MenuBarIcon.nextFrame(0, badge: badge), 0,
                "\(badge) is not animated; frame must not change",
            )
            XCTAssertEqual(
                MenuBarIcon.nextFrame(3, badge: badge), 3,
                "\(badge) is not animated; frame must not change",
            )
        }
    }

    func testAnimatedBadgesAdvance() {
        for badge in [BadgeKind.recording, .transcribing, .diarizing, .processing] {
            XCTAssertEqual(MenuBarIcon.nextFrame(0, badge: badge), 1)
            XCTAssertEqual(MenuBarIcon.nextFrame(1, badge: badge), 2)
        }
    }

    func testAnimatedBadgeWrapsAtFrameCount() {
        let last = MenuBarIcon.frameCount - 1
        XCTAssertEqual(MenuBarIcon.nextFrame(last, badge: .recording), 0)
    }

    /// A static badge must not wake the main run loop: the menu-bar icon sits
    /// on one for most of the app's life, and a tick that changes nothing
    /// still costs a wake-up every 0.4 s.
    @MainActor
    func testStaticBadgesSubscribeToNoTimer() {
        let ticked = expectation(description: "a static badge ticked")
        ticked.isInverted = true
        ticked.assertForOverFulfill = false
        let subscriptions = BadgeKind.allCases.filter { !$0.isAnimated }.map { badge in
            MenuBarIcon.animationTicks(for: badge).sink { _ in ticked.fulfill() }
        }
        wait(for: [ticked], timeout: 0.6)
        subscriptions.forEach { $0.cancel() }
    }

    @MainActor
    func testAnimatedBadgesTick() {
        for badge in BadgeKind.allCases where badge.isAnimated {
            let ticked = expectation(description: "\(badge) ticked")
            ticked.assertForOverFulfill = false
            let subscription = MenuBarIcon.animationTicks(for: badge).sink { _ in ticked.fulfill() }
            wait(for: [ticked], timeout: 2)
            subscription.cancel()
        }
    }

    // Regression guard: the animation timer must stay `.default`. `.common`
    // includes `.eventTracking`, which fires the @MainActor tick inside the
    // status-bar menu's nested run loop and crashes (EXC_BAD_ACCESS).
    func testAnimationTimerAvoidsEventTrackingMode() {
        XCTAssertEqual(MenuBarIcon.animationRunLoopMode, .default)
        XCTAssertNotEqual(MenuBarIcon.animationRunLoopMode, .common)
    }
}
