import XCTest

@testable import MeetingTranscriber

final class MenuBarIconTests: XCTestCase {

    func testImageWithNoBadgeIsTemplate() {
        let image = MenuBarIcon.image(badge: .none)
        XCTAssertTrue(image.isTemplate)
    }

    func testImageSizeIs18x18() {
        let image = MenuBarIcon.image(badge: .none)
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
        XCTAssertFalse(BadgeKind.none.isAnimated)
        XCTAssertFalse(BadgeKind.done.isAnimated)
    }

    func testAllAnimationFramesProduceValidImages() {
        let animatedBadges: [BadgeKind] = [.recording, .transcribing, .diarizing, .processing]
        for badge in animatedBadges {
            for frame in 0..<MenuBarIcon.frameCount {
                let image = MenuBarIcon.image(badge: badge, animationFrame: frame)
                XCTAssertTrue(image.isTemplate, "\(badge) frame \(frame)")
                XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
                XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
            }
        }
    }
}
