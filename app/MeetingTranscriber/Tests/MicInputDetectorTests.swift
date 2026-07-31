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

    /// Exercises the real Core Audio bridging, which the injected
    /// `processProvider` otherwise hides: hand-rolled property sizes and an
    /// `UnsafeMutablePointer` round-trip for the CFString. A mistake there
    /// yields garbage rather than a compile error, so assert the shape of what
    /// comes back. The list may legitimately be empty on a headless runner.
    func testSystemAudioProcessesReturnsWellFormedSnapshots() {
        for snapshot in MicInputDetector.systemAudioProcesses() {
            XCTAssertFalse(
                snapshot.bundleID.isEmpty,
                "a snapshot is only produced for a process that reported a bundle ID",
            )
            XCTAssertGreaterThan(snapshot.pid, 0, "\(snapshot.bundleID) reported a non-positive pid")
        }
    }

    /// A watched app with no `AppMeetingPattern` must still detect, with a
    /// synthesised pattern and the placeholder title, instead of dropping the
    /// meeting on the floor.
    func testWatchedAppWithoutMeetingPatternStillDetects() {
        let detector = MicInputDetector(
            patterns: [MicInputDetector.MicPattern(appName: "Unlisted Call App", bundleIDs: ["com.example.unlisted"])],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.processProvider = { [snapshot("com.example.unlisted", pid: 99)] }

        let result = detector.checkOnce()
        XCTAssertEqual(result?.pattern.appName, "Unlisted Call App")
        XCTAssertEqual(result?.pattern.ownerNames, ["Unlisted Call App"])
        XCTAssertEqual(result?.windowPID, 99)
        XCTAssertEqual(result?.windowTitle, "Unlisted Call App Call")
    }

    /// The default install watches none of these apps, and then this channel
    /// must cost nothing: no Core Audio enumeration per poll, and no diagnostic
    /// naming the bundle of every app that touches the mic.
    func testUnwatchedInstallDoesNotEnumerateAudioProcesses() {
        let detector = MicInputDetector(patterns: MicInputDetector.patterns(watching: []), confirmationCount: 1)
        detector.windowListProvider = { [] }
        var providerCalls = 0
        detector.processProvider = {
            providerCalls += 1
            return [snapshot("com.tencent.xinWeChat")]
        }
        XCTAssertNil(detector.checkOnce())
        XCTAssertEqual(providerCalls, 0)
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

    /// The international build ships as VooV Meeting under its own bundle ID,
    /// so watching only the mainland one would miss those users entirely.
    func testDetectsVooVMeetingInternationalBundle() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.tencentmeeting")] }
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
