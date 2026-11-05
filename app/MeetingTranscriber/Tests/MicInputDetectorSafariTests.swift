@testable import MeetingTranscriber
import XCTest

// MARK: - Test Helpers

private let gpuBundle = "com.apple.WebKit.GPU"
private let gpuPID: pid_t = 85373
private let safariPID: pid_t = 85350

private func snapshot(
    _ bundleID: String,
    pid: pid_t = 4321,
    running: Bool = true,
) -> MicInputDetector.AudioProcessSnapshot {
    MicInputDetector.AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: running)
}

private func owner(_ bundleID: String, pid: pid_t = safariPID) -> MicInputDetector.ResponsibleApp {
    MicInputDetector.ResponsibleApp(pid: pid, bundleID: bundleID)
}

/// A detector watching browser meetings (and any extra app toggles), whose
/// GPU process is attributed to `ownerBundleID`.
private func makeDetector(
    watching extra: [String] = [],
    ownerBundleID: String? = "com.apple.Safari",
    confirmationCount: Int = 1,
) -> MicInputDetector {
    let detector = MicInputDetector(
        patterns: MicInputDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName] + extra),
        confirmationCount: confirmationCount,
    )
    detector.windowListProvider = { [] }
    detector.responsibleAppProvider = { pid in
        guard pid == gpuPID, let ownerBundleID else { return nil }
        return owner(ownerBundleID)
    }
    return detector
}

// MARK: - Safari browser meetings

final class MicInputDetectorSafariTests: XCTestCase {
    func testSafariGPUProcessHoldingTheMicIsASafariMeeting() throws {
        let detector = makeDetector()
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Safari")
        XCTAssertEqual(meeting.pattern.ownerNames, ["Safari"])
        XCTAssertEqual(meeting.ownerName, "Safari")
        XCTAssertEqual(meeting.windowTitle, "Safari Call")
    }

    /// The mic is open on the pre-join screen and on any page that asks for
    /// it, so a Safari hit must prompt, never auto-record.
    func testSafariMeetingRequiresConsent() throws {
        let detector = makeDetector()
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        XCTAssertTrue(try XCTUnwrap(detector.checkOnce()).pattern.requiresRecordingConsent)
    }

    /// The GPU process emits no sound of its own that the recorder could
    /// widen from; Safari's main process can (`ProcessResponsibility.tapPIDs`).
    func testSafariMeetingTapsSafarisMainProcess() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        XCTAssertEqual(detector.checkOnce()?.windowPID, safariPID)
    }

    func testWebViewInAnotherAppIsIgnored() {
        let detector = makeDetector(ownerBundleID: "com.example.webview-app")
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        XCTAssertNil(detector.checkOnce())
    }

    /// The App Store build cannot resolve responsibility, and an unattributed
    /// GPU process must not be guessed to be Safari's.
    func testUnresolvableOwnerIsIgnored() {
        let detector = makeDetector(ownerBundleID: nil)
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        XCTAssertNil(detector.checkOnce())
    }

    func testSafariTechnologyPreviewIsItsOwnIdentity() {
        let detector = makeDetector(ownerBundleID: "com.apple.SafariTechnologyPreview")
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Safari Technology Preview")
    }

    func testBrowserToggleSelectsTheSafariPatterns() {
        XCTAssertTrue(
            MicInputDetector.patterns(watching: []).isEmpty,
            "with Browser Web Meetings off, Safari must not be watched",
        )
        let watched = MicInputDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName])
        XCTAssertEqual(watched.map(\.appName), MicInputDetector.safariPatterns.map(\.appName))
    }

    func testDeniedSafariNeverConfirms() {
        let detector = makeDetector()
        detector.isIdentityDenied = { $0 == "Safari" }
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        XCTAssertNil(detector.checkOnce())
        XCTAssertNil(detector.checkOnce())
    }

    func testSafariWindowSuppliesTheTitle() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        detector.windowListProvider = {
            [
                ["kCGWindowOwnerName": "Google Chrome", "kCGWindowName": "Other tab"],
                ["kCGWindowOwnerName": "Safari", "kCGWindowName": "Meet – abc-defg-hij"],
            ]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Meet – abc-defg-hij")
    }

    /// Measured: leaving the call stops input with the tab still open.
    func testMeetingEndsWhenSafariStopsCapturing() throws {
        let detector = makeDetector()
        var running = true
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID, running: running)] }
        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertTrue(detector.isMeetingActive(meeting))
        running = false
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    /// A WKWebView app capturing the mic must not keep a Safari recording alive.
    func testOtherAppsGPUProcessDoesNotKeepASafariMeetingAlive() throws {
        let detector = makeDetector()
        var processes = [snapshot(gpuBundle, pid: gpuPID)]
        detector.processProvider = { processes }
        let meeting = try XCTUnwrap(detector.checkOnce())
        processes = [snapshot(gpuBundle, pid: 999)]
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    /// Responsibility is a syscall per process: ask it only for processes a
    /// Safari pattern matches by bundle.
    func testOwnerIsResolvedOnlyForGPUProcesses() {
        let detector = makeDetector(watching: ["WeChat"])
        var lookups = 0
        detector.responsibleAppProvider = { _ in
            lookups += 1
            return nil
        }
        detector.processProvider = { [snapshot("com.tencent.xinWeChat"), snapshot("com.apple.VoiceMemos")] }
        _ = detector.checkOnce()
        XCTAssertEqual(lookups, 0)
    }

    /// A custom `com.apple.WebKit.GPU` entry is not swallowed by the Safari
    /// patterns: it still sees the GPU processes other apps own, and a
    /// Safari-owned one is filed under Safari.
    func testCustomGPUEntryKeepsTheProcessesSafariDoesNotOwn() {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(
                watching: [AppMeetingPattern.browserMeetings.appName], customBundleIDs: [gpuBundle],
            ),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in nil }
        var ownerBundleID = "com.example.webview-app"
        detector.responsibleAppProvider = { _ in owner(ownerBundleID) }
        detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }

        let custom = detector.checkOnce()
        XCTAssertNotNil(custom)
        XCTAssertNotEqual(custom?.pattern.appName, "Safari")

        let fresh = MicInputDetector(
            patterns: MicInputDetector.patterns(
                watching: [AppMeetingPattern.browserMeetings.appName], customBundleIDs: [gpuBundle],
            ),
            confirmationCount: 1,
        )
        fresh.windowListProvider = { [] }
        ownerBundleID = "com.apple.Safari"
        fresh.responsibleAppProvider = { _ in owner(ownerBundleID) }
        fresh.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
        XCTAssertEqual(fresh.checkOnce()?.pattern.appName, "Safari")
    }

    // MARK: - Sharing the poll with native call apps

    /// A Safari call whose prompt is parked re-confirms every poll. A native
    /// call starting meanwhile must take the slot, whatever the dictionary
    /// order (repeated, since that order varies per process and instance).
    func testNativeCallWinsThePollOverAParkedSafariCall() {
        for _ in 0 ..< 20 {
            let detector = makeDetector(watching: ["WhatsApp"])
            detector.processProvider = { [snapshot(gpuBundle, pid: gpuPID), snapshot("net.whatsapp.WhatsApp", pid: 77)] }
            XCTAssertEqual(detector.checkOnce()?.pattern.appName, "WhatsApp")
        }
    }

    /// Returning the Safari meeting must not skip resetting another app's
    /// counter, or a single stale hit would later confirm in one poll.
    func testStaleHitIsResetWhileSafariIsReturned() {
        let detector = makeDetector(watching: ["WeChat"], confirmationCount: 2)
        var processes = [snapshot(gpuBundle, pid: gpuPID), snapshot("com.tencent.xinWeChat")]
        detector.processProvider = { processes }

        XCTAssertNil(detector.checkOnce(), "first poll confirms nothing")
        processes = [snapshot(gpuBundle, pid: gpuPID)]
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Safari")
        processes = [snapshot(gpuBundle, pid: gpuPID), snapshot("com.tencent.xinWeChat")]
        XCTAssertEqual(
            detector.checkOnce()?.pattern.appName, "Safari",
            "WeChat's hit from two polls ago was interrupted and must not count",
        )
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "WeChat")
    }

    // MARK: - Wiring

    @MainActor
    func testDefaultDetectorWatchesSafariAndHonoursTheDenyList() throws {
        func detector(browserMeetings: Bool, denied: [String] = []) throws -> MicInputDetector {
            let suite = "SafariWatchWiring-\(getpid())-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
            settings.watchBrowserMeetings = browserMeetings
            settings.consentDeniedApps = denied
            let mic = try XCTUnwrap(
                WatchingController.defaultDetectors(settings: settings)
                    .compactMap { $0 as? MicInputDetector }.first,
            )
            mic.windowListProvider = { [] }
            mic.responsibleAppProvider = { _ in owner("com.apple.Safari") }
            mic.processProvider = { [snapshot(gpuBundle, pid: gpuPID)] }
            return mic
        }

        let watched = try detector(browserMeetings: true)
        _ = watched.checkOnce()
        XCTAssertEqual(watched.checkOnce()?.pattern.appName, "Safari")

        let off = try detector(browserMeetings: false)
        _ = off.checkOnce()
        XCTAssertNil(off.checkOnce(), "Browser Web Meetings off must leave Safari alone")

        let denied = try detector(browserMeetings: true, denied: ["Safari"])
        _ = denied.checkOnce()
        XCTAssertNil(denied.checkOnce(), "a Safari on the deny list must never confirm")
    }
}
