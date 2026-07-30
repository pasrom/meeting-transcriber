@testable import MeetingTranscriber
import XCTest

// MARK: - Test Helpers

private func makeDetector(confirmationCount: Int = 1) -> MicInputDetector {
    let detector = MicInputDetector(confirmationCount: confirmationCount)
    detector.windowListProvider = { [] } // no real windows in unit tests
    return detector
}

private func snapshot(
    _ bundleID: String,
    pid: pid_t = 4321,
    running: Bool = true,
) -> MicInputDetector.AudioProcessSnapshot {
    MicInputDetector.AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: running)
}

// MARK: - Detection Tests

final class MicInputDetectorTests: XCTestCase {
    func testNoProcessesReturnsNil() {
        let detector = makeDetector()
        detector.processProvider = { [] }
        XCTAssertNil(detector.checkOnce())
    }

    func testDetectsWeChatCall() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", pid: 777)] }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "WeChat")
        // No window title available (empty list) → clean placeholder.
        XCTAssertEqual(result?.windowTitle, "WeChat Call")
        XCTAssertEqual(result?.windowPID, 777)
    }

    func testDetectsTencentMeetingViaWemeetBundle() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.wemeet")] }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Tencent Meeting")
    }

    func testIdleProcessDoesNotDetect() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", running: false)] }
        XCTAssertNil(detector.checkOnce())
    }

    func testUnwatchedBundleDoesNotDetect() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.apple.VoiceMemos")] }
        XCTAssertNil(detector.checkOnce())
    }

    func testConfirmationThresholdNeedsConsecutiveHits() {
        let detector = makeDetector(confirmationCount: 2)
        detector.processProvider = { [snapshot("com.tencent.xinWeChat")] }
        XCTAssertNil(detector.checkOnce(), "first hit must not confirm")
        XCTAssertNotNil(detector.checkOnce(), "second consecutive hit confirms")
    }

    func testInterruptedHitsResetCounter() {
        let detector = makeDetector(confirmationCount: 2)
        var running = true
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", running: running)] }
        XCTAssertNil(detector.checkOnce())
        running = false
        XCTAssertNil(detector.checkOnce())
        running = true
        XCTAssertNil(detector.checkOnce(), "counter must restart after the gap")
    }

    func testIsMeetingActiveTracksInputState() throws {
        let detector = makeDetector()
        var running = true
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", running: running)] }
        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertTrue(detector.isMeetingActive(meeting))
        running = false
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    func testIsMeetingActiveIsFalseForForeignApp() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat")] }
        let foreign = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Weekly | Microsoft Teams",
            ownerName: "MSTeams",
            windowPID: 1,
        )
        XCTAssertFalse(detector.isMeetingActive(foreign), "assertion-detected apps are not this detector's business")
    }

    func testResetStartsCooldown() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat")] }
        XCTAssertNotNil(detector.checkOnce())
        detector.reset(appName: "WeChat")
        XCTAssertNil(detector.checkOnce(), "cooldown must suppress re-detection")
    }

    func testEveryDefaultPatternHasMeetingPattern() {
        // Drift guard, mirroring the assertion detector's: a mic pattern with no
        // AppMeetingPattern would silently fall back to placeholder titles.
        for pattern in MicInputDetector.defaultPatterns {
            XCTAssertNotNil(
                AppMeetingPattern.forAppName(pattern.appName),
                "MicPattern \(pattern.appName) has no AppMeetingPattern",
            )
        }
    }

    func testPatternsWatchingFiltersBySelection() {
        let all = MicInputDetector.patterns(watching: ["WeChat", "Tencent Meeting", "FaceTime", "WhatsApp"])
        XCTAssertEqual(all.count, MicInputDetector.defaultPatterns.count)
        let none = MicInputDetector.patterns(watching: [])
        XCTAssertTrue(none.isEmpty)
        let one = MicInputDetector.patterns(watching: ["WeChat"])
        XCTAssertEqual(one.map(\.appName), ["WeChat"])
    }
}

// MARK: - Composite Tests

final class CompositeMeetingDetectorTests: XCTestCase {
    private func micDetector(bundleID: String = "com.tencent.xinWeChat") -> MicInputDetector {
        let detector = MicInputDetector(confirmationCount: 1)
        detector.windowListProvider = { [] }
        detector.processProvider = { [snapshot(bundleID)] }
        return detector
    }

    private func assertionDetector(active: Bool) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            active
                ? makeAssertionDict(pid: 55, processName: "MSTeams", assertName: "Microsoft Teams Call in progress")
                : [:]
        }
        return detector
    }

    func testFirstHitWins() {
        let composite = CompositeMeetingDetector([assertionDetector(active: true), micDetector()])
        XCTAssertEqual(composite.checkOnce()?.pattern.appName, "Microsoft Teams")
    }

    func testFallsThroughToLaterDetector() {
        let composite = CompositeMeetingDetector([assertionDetector(active: false), micDetector()])
        XCTAssertEqual(composite.checkOnce()?.pattern.appName, "WeChat")
    }

    func testLivenessIsPerStrategyOr() throws {
        let mic = micDetector()
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        let meeting = try XCTUnwrap(composite.checkOnce())
        XCTAssertTrue(composite.isMeetingActive(meeting))
        mic.processProvider = { [] }
        XCTAssertFalse(composite.isMeetingActive(meeting))
    }
}
