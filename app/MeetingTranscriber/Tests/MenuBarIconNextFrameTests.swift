@testable import MeetingTranscriber
import XCTest

final class MenuBarIconNextFrameTests: XCTestCase {
    func testStaticBadgesDoNotAdvance() {
        // Derived, not hardcoded: `.error` and `.userAction` moved into the
        // animated set so their exclamation blinks (a static failure badge is
        // one a user scrolls past). Deriving keeps this honest if the set
        // changes again.
        for badge in BadgeKind.allCases where !badge.isAnimated {
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

    // Regression guard: the animation timer must stay `.default`. `.common`
    // includes `.eventTracking`, which fires the @MainActor tick inside the
    // status-bar menu's nested run loop and crashes (EXC_BAD_ACCESS).
    func testAnimationTimerAvoidsEventTrackingMode() {
        XCTAssertEqual(MenuBarIcon.animationRunLoopMode, .default)
        XCTAssertNotEqual(MenuBarIcon.animationRunLoopMode, .common)
    }
}
