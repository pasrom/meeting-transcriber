@testable import MeetingTranscriber
import SnapshotTesting
import XCTest

final class MenuBarIconSnapshotTests: XCTestCase {
    private var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    override func invokeTest() {
        withSnapshotTesting(record: .missing) {
            super.invokeTest()
        }
    }

    func testStaticBadgeSnapshots() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        let staticBadges: [BadgeKind] = [.inactive, .userAction, .done, .error, .updateAvailable]
        for badge in staticBadges {
            let image = MenuBarIcon.image(badge: badge)
            assertSnapshot(of: image, as: .image, named: "\(badge)")
        }
    }

    func testRecordingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .recording, animationFrame: frame)
            assertSnapshot(of: image, as: .image, named: "frame\(frame)")
        }
    }

    func testTranscribingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .transcribing, animationFrame: frame)
            assertSnapshot(of: image, as: .image, named: "frame\(frame)")
        }
    }

    func testDiarizingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .diarizing, animationFrame: frame)
            assertSnapshot(of: image, as: .image, named: "frame\(frame)")
        }
    }

    func testProcessingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .processing, animationFrame: frame)
            assertSnapshot(of: image, as: .image, named: "frame\(frame)")
        }
    }

    func testAllBadgesProduceNonEmptyImages() {
        for badge in BadgeKind.allCases {
            let frameCount = badge.isAnimated ? MenuBarIcon.frameCount : 1
            for frame in 0 ..< frameCount {
                let image = MenuBarIcon.image(badge: badge, animationFrame: frame)
                // Verify the image has actual pixel data (not a blank image)
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff)
                else {
                    XCTFail("Could not get bitmap for \(badge) frame \(frame)")
                    continue
                }
                // At least some pixels should be non-transparent
                var hasContent = false
                for y in 0 ..< bitmap.pixelsHigh {
                    for x in 0 ..< bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y),
                           color.alphaComponent > 0 {
                            hasContent = true
                            break
                        }
                    }
                    if hasContent { break }
                }
                XCTAssertTrue(hasContent, "\(badge) frame \(frame) should have visible content")
            }
        }
    }
}
