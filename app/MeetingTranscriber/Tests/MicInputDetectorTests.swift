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

private func customPattern(appName: String, bundleID: String) -> MicInputDetector.MicPattern {
    MicInputDetector.MicPattern(appName: appName, bundleIDs: [bundleID], matchesHelpers: true, usesBuiltInMeetingPattern: false)
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
        let all = MicInputDetector.patterns(watching: ["WeChat", "Tencent Meeting", "FaceTime", "WhatsApp", "Slack"])
        XCTAssertEqual(all.count, MicInputDetector.defaultPatterns.count)
        let none = MicInputDetector.patterns(watching: [])
        XCTAssertTrue(none.isEmpty)
        let one = MicInputDetector.patterns(watching: ["WeChat"])
        XCTAssertEqual(one.map(\.appName), ["WeChat"])
    }

    /// Every ID of a selected built-in counts for the dedup, not just its
    /// first (for Tencent Meeting the second is the VooV build).
    func testCustomEntryMatchingASecondaryBuiltInBundleIDIsDropped() throws {
        let tencent = try XCTUnwrap(MicInputDetector.defaultPatterns.first { $0.appName == "Tencent Meeting" })
        let secondary = try XCTUnwrap(tencent.bundleIDs.dropFirst().first)
        let patterns = MicInputDetector.patterns(watching: ["Tencent Meeting"], customBundleIDs: [secondary])
        XCTAssertEqual(patterns.map(\.bundleIDs), [tencent.bundleIDs])
    }

    /// The other boundary of the rule: a built-in that does not match helpers
    /// (WeChat excludes its mini-program helpers on purpose) does not swallow
    /// a custom entry for one.
    func testCustomHelperEntryIsKeptWhenTheBuiltInDoesNotMatchHelpers() throws {
        let weChat = try XCTUnwrap(MicInputDetector.defaultPatterns.first { $0.appName == "WeChat" })
        XCTAssertFalse(weChat.matchesHelpers, "precondition: WeChat's built-in pattern does not match helpers")
        let helper = "com.tencent.xinWeChat.IPCHelper"
        let patterns = MicInputDetector.patterns(watching: ["WeChat"], customBundleIDs: [helper])
        XCTAssertEqual(patterns.map(\.bundleIDs), [weChat.bundleIDs, [helper]])
        XCTAssertEqual(patterns.map(\.usesBuiltInMeetingPattern), [true, false])
    }

    func testCustomAppDetectsViaHelperAndTapsMainApp() throws {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: [], customBundleIDs: ["com.example.callapp"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { $0 == "com.example.callapp" ? 100 : nil }
        detector.processProvider = { [snapshot("com.example.callapp.helper", pid: 555)] }

        let result = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(result.windowPID, 100)
        XCTAssertTrue(detector.isMeetingActive(result))
    }

    func testCustomAppMainProcessKeepsItsOwnPID() {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: [], customBundleIDs: ["com.example.callapp"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in 100 }
        detector.processProvider = { [snapshot("com.example.callapp", pid: 555)] }

        XCTAssertEqual(detector.checkOnce()?.windowPID, 555)
    }

    func testCustomAppIgnoresBundleSharingOnlyAPrefix() {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: [], customBundleIDs: ["com.example.callapp"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.processProvider = { [snapshot("com.example.callappextra", pid: 555)] }

        XCTAssertNil(detector.checkOnce())
    }

    func testUnrelatedCustomAppNamedLikeABuiltInStaysActiveWhileItsHelperHoldsTheMic() throws {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: ["WeChat"])
                + [customPattern(appName: "WeChat", bundleID: "com.example.wechat")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in nil }
        detector.processProvider = { [snapshot("com.example.wechat.helper")] }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testCustomAppNamedLikeABuiltInInAnotherCaseStaysActiveAndCoolsDown() throws {
        let detector = MicInputDetector(
            patterns: [customPattern(appName: "Whatsapp", bundleID: "com.example.whatsapp")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.processProvider = { [snapshot("com.example.whatsapp")] }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Whatsapp")
        XCTAssertTrue(detector.isMeetingActive(meeting))

        detector.reset(appName: meeting.pattern.appName)
        XCTAssertNil(detector.checkOnce(), "cooldown must apply under the name the meeting was reported with")
    }

    @MainActor
    func testDefaultDetectorReadsCustomWatchedApps() throws {
        func detector(customApps: [String]) throws -> MicInputDetector {
            let suite = "CustomWatchWiring-\(getpid())-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
            settings.watchCustomApps = customApps
            let mic = try XCTUnwrap(
                WatchingController.defaultDetectors(settings: settings)
                    .compactMap { $0 as? MicInputDetector }.first,
            )
            mic.windowListProvider = { [] }
            mic.processProvider = { [snapshot("com.example.callapp")] }
            return mic
        }

        let watched = try detector(customApps: ["com.example.callapp"])
        _ = watched.checkOnce()
        XCTAssertNotNil(watched.checkOnce(), "a custom watched app holding the mic must fire")

        let unwatched = try detector(customApps: [])
        _ = unwatched.checkOnce()
        XCTAssertNil(unwatched.checkOnce(), "without the entry the same app must be ignored")
    }

    func testCustomAppDoesNotInheritTheBuiltInMeetingPatternOfItsName() {
        let meetingPattern = customPattern(appName: "Zoom", bundleID: "com.example.zoom").meetingPattern
        XCTAssertEqual(meetingPattern.ownerNames, ["Zoom"])
        XCTAssertTrue(meetingPattern.meetingPatterns.isEmpty)
        XCTAssertFalse(MicInputDetector.customPattern(bundleID: "com.example.zoom").usesBuiltInMeetingPattern)
    }

    func testBuiltInPatternsDoNotMatchHelpers() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat.MiniProgram")] }
        XCTAssertNil(detector.checkOnce())
    }

    func testAppDisplayNameUsesInstalledAppNameAndFallsBackToBundleID() {
        XCTAssertEqual(MicInputDetector.appDisplayName(bundleID: "com.apple.finder"), "Finder")
        XCTAssertEqual(MicInputDetector.appDisplayName(bundleID: "com.example.not-installed"), "com.example.not-installed")
    }

    func testDefaultMainAppPIDProviderFindsNothingForAnAppThatIsNotRunning() {
        XCTAssertNil(makeDetector().mainAppPIDProvider("com.example.not-installed"))
    }
}
