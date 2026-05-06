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
}
