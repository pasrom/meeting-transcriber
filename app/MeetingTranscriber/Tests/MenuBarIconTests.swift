@testable import MeetingTranscriber
import XCTest

final class MenuBarIconTests: XCTestCase {
    func testImageWithNoBadgeIsTemplate() {
        let image = MenuBarIcon.image(badge: .inactive)
        XCTAssertTrue(image.isTemplate)
    }

    func testImageSizeIs18x18() {
        let image = MenuBarIcon.image(badge: .inactive)
        XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
    }

    func testAllBadgeKindsProduceValidImages() {
        for badge in BadgeKind.allCases {
            let image = MenuBarIcon.image(badge: badge)
            XCTAssertTrue(image.isTemplate, "Badge \(badge) should produce a template image")
            XCTAssertEqual(image.size.width, 18, accuracy: 0.01, "Badge \(badge) width")
            XCTAssertEqual(image.size.height, 18, accuracy: 0.01, "Badge \(badge) height")
        }
    }

    func testAnimatedBadgeKinds() {
        XCTAssertTrue(BadgeKind.recording.isAnimated)
        XCTAssertTrue(BadgeKind.transcribing.isAnimated)
        XCTAssertTrue(BadgeKind.diarizing.isAnimated)
        XCTAssertTrue(BadgeKind.processing.isAnimated)
        XCTAssertFalse(BadgeKind.inactive.isAnimated)
        XCTAssertFalse(BadgeKind.done.isAnimated)
    }

    func testAllAnimationFramesProduceValidImages() {
        let animatedBadges: [BadgeKind] = [.recording, .transcribing, .diarizing, .processing]
        for badge in animatedBadges {
            for frame in 0 ..< MenuBarIcon.frameCount {
                let image = MenuBarIcon.image(badge: badge, animationFrame: frame)
                XCTAssertTrue(image.isTemplate, "\(badge) frame \(frame)")
                XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
                XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
            }
        }
    }

    // MARK: - Layout Math

    func testBarsLayoutCentersHorizontally() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.barsLayout(in: rect)
        // 5 bars × 2.2 width + 4 gaps × (3.6 - 2.2) = 11 + 5.6 = 16.6
        // left = (18 - 16.6) / 2 = 0.7
        let barsWidth: CGFloat = 5 * 2.2 + 4 * (3.6 - 2.2)
        let expectedLeft = (18 - barsWidth) / 2
        XCTAssertEqual(layout.left, expectedLeft, accuracy: 0.01)
    }

    func testBarsLayoutCentersVertically() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.barsLayout(in: rect)
        XCTAssertEqual(layout.centerY, 9.0, accuracy: 0.01)
    }

    func testTextLayoutLeft() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.textLayout(in: rect)
        XCTAssertEqual(layout.left, 18 * 0.12, accuracy: 0.01)
    }

    func testTextLayoutTopCentersVertically() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.textLayout(in: rect)
        // 5 lines × 1.4 height + 4 gaps × (2.8 - 1.4) = 7 + 5.6 = 12.6
        // top = 9 + 12.6/2 = 15.3
        let linesHeight: CGFloat = 5 * 1.4 + 4 * (2.8 - 1.4)
        let expectedTop = 18.0 / 2 + linesHeight / 2
        XCTAssertEqual(layout.top, expectedTop, accuracy: 0.01)
    }
}
