@testable import MeetingTranscriber
import SnapshotTesting
import XCTest

@MainActor
final class MenuBarIconSnapshotTests: XCTestCase {
    private var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Byte-exact image comparison tests the rasteriser as much as the icon. An
    /// Xcode update re-renders every badge identically to the eye and fails all
    /// 29 references at once, which is exactly what happened between May and
    /// August and cost half an hour to prove harmless. A perceptual tolerance
    /// absorbs that.
    ///
    /// It is not blind: the smallest genuine difference in this suite is one
    /// animation frame against its neighbour, and those still fail against each
    /// other at these values. Anything a person would call a changed badge fails
    /// by a wide margin.
    private static let icon = Snapshotting<NSImage, NSImage>.image(
        precision: 0.99, perceptualPrecision: 0.98,
    )

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
            assertSnapshot(of: image, as: Self.icon, named: "\(badge)")
        }
    }

    func testRecordingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .recording, animationFrame: frame)
            assertSnapshot(of: image, as: Self.icon, named: "frame\(frame)")
        }
    }

    func testTranscribingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .transcribing, animationFrame: frame)
            assertSnapshot(of: image, as: Self.icon, named: "frame\(frame)")
        }
    }

    func testDiarizingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .diarizing, animationFrame: frame)
            assertSnapshot(of: image, as: Self.icon, named: "frame\(frame)")
        }
    }

    func testProcessingAnimationFrames() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let image = MenuBarIcon.image(badge: .processing, animationFrame: frame)
            assertSnapshot(of: image, as: Self.icon, named: "frame\(frame)")
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
