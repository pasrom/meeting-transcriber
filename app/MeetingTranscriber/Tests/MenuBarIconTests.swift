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
            if badge == .error {
                XCTAssertFalse(image.isTemplate, "Error badge should be non-template (colored)")
            } else {
                XCTAssertTrue(image.isTemplate, "Badge \(badge) should produce a template image")
            }
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

    // MARK: - Frame Wrapping

    func testAnimationFrameWrapsAroundFrameCount() {
        let badge = BadgeKind.recording
        let normal = MenuBarIcon.image(badge: badge, animationFrame: 2)
        let wrapped = MenuBarIcon.image(badge: badge, animationFrame: 2 + MenuBarIcon.frameCount)
        XCTAssertTrue(normal.isTemplate)
        XCTAssertTrue(wrapped.isTemplate)
        XCTAssertEqual(normal.size, wrapped.size)
    }

    func testLargeAnimationFrameDoesNotCrash() {
        for badge in BadgeKind.allCases where badge.isAnimated {
            let image = MenuBarIcon.image(badge: badge, animationFrame: 999)
            XCTAssertTrue(image.isTemplate, "Large frame index should wrap safely for \(badge)")
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

    // MARK: - BadgeKind.compute()

    // 1. Recording while watchLoop recording
    func testCompute_watchLoopRecording_returnsRecording() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .recording)
    }

    // 2. Recording takes priority over transcriberState
    func testCompute_watchLoopRecording_priorityOverTranscriberState() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .transcribing,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .recording)
    }

    // 3. UserAction for waitingForSpeakerCount
    func testCompute_waitingForSpeakerCount_returnsUserAction() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .waitingForSpeakerCount,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .userAction)
    }

    // 4. UserAction for waitingForSpeakerNames
    func testCompute_waitingForSpeakerNames_returnsUserAction() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .waitingForSpeakerNames,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .userAction)
    }

    // 5. Done for protocolReady
    func testCompute_protocolReady_returnsDone() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .protocolReady,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .done)
    }

    // 6. Error for transcriberError
    func testCompute_transcriberError_returnsError() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .error,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .error)
    }

    // 7. Transcribing for transcriberTranscribing
    func testCompute_transcriberTranscribing_returnsTranscribing() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .transcribing,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 8. Transcribing for recordingDone
    func testCompute_recordingDone_returnsTranscribing() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .recordingDone,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 9. Processing for generatingProtocol
    func testCompute_generatingProtocol_returnsProcessing() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .generatingProtocol,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 10. ActiveJob transcribing (watchLoop inactive)
    func testCompute_activeJobTranscribing_returnsTranscribing() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .transcribing,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 11. ActiveJob diarizing
    func testCompute_activeJobDiarizing_returnsDiarizing() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .diarizing,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .diarizing)
    }

    // 12. ActiveJob generatingProtocol → processing
    func testCompute_activeJobGeneratingProtocol_returnsProcessing() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .generatingProtocol,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 13. ActiveJob waiting → processing
    func testCompute_activeJobWaiting_returnsProcessing() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .waiting,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 14. ActiveJob done → processing
    func testCompute_activeJobDone_returnsProcessing() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .done,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 15. ActiveJob error → processing
    func testCompute_activeJobError_returnsProcessing() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .error,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 16. UpdateAvailable when all idle
    func testCompute_updateAvailable_returnsUpdateAvailable() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: true,
        )
        XCTAssertEqual(result, .updateAvailable)
    }

    // 17. Inactive when all idle
    func testCompute_allIdle_returnsInactive() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .inactive)
    }

    // 18. WatchLoop active but idle transcriberState → inactive
    func testCompute_watchLoopActiveIdleTranscriber_returnsInactive() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .inactive)
    }

    // 19. ActiveJob takes priority over updateAvailable
    func testCompute_activeJob_priorityOverUpdateAvailable() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .transcribing,
            updateAvailable: true,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 20. WatchLoop recording takes priority over activeJob and updateAvailable
    func testCompute_watchLoopRecording_priorityOverActiveJobAndUpdate() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .idle,
            activeJobState: .transcribing,
            updateAvailable: true,
        )
        XCTAssertEqual(result, .recording)
    }

    // 21. WatchLoop active with .watching transcriberState → falls through to inactive
    func testCompute_watchLoopActiveWatchingState_fallsThroughToInactive() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .watching,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .inactive)
    }

    func testCompute_permissionBroken_returnsError() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
            permissionProblem: true,
        )
        XCTAssertEqual(result, .error)
    }

    func testCompute_recordingOverridesPermissionProblem() {
        let result = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
            permissionProblem: true,
        )
        XCTAssertEqual(result, .recording)
    }

    func testCompute_permissionProblemOverridesUpdate() {
        let result = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: true,
            permissionProblem: true,
        )
        XCTAssertEqual(result, .error)
    }
}
