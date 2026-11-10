@testable import MeetingTranscriber
import XCTest

/// `makeAssertionDict` is shared from PowerAssertionDetectorTests (internal);
/// the mic snapshot helper is file-private there, so keep a local one.
private func micSnapshot(_ bundleID: String) -> MicInputDetector.AudioProcessSnapshot {
    MicInputDetector.AudioProcessSnapshot(bundleID: bundleID, pid: 4321, isRunningInput: true)
}

final class CompositeMeetingDetectorTests: XCTestCase {
    private func micDetector(bundleID: String = "com.tencent.xinWeChat") -> MicInputDetector {
        let detector = MicInputDetector(confirmationCount: 1)
        detector.windowListProvider = { [] }
        detector.processProvider = { [micSnapshot(bundleID)] }
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

    func testNoStrategySeesAnythingReturnsNil() {
        let mic = MicInputDetector(confirmationCount: 1)
        mic.windowListProvider = { [] }
        mic.processProvider = { [] }
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        XCTAssertNil(composite.checkOnce())
    }

    func testResetReachesEveryStrategy() throws {
        // Observable proof that the fan-out happens: after a reset naming the
        // app, the mic strategy's cooldown suppresses the very same process
        // snapshot that fired a moment earlier.
        let mic = micDetector()
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        let meeting = try XCTUnwrap(composite.checkOnce())

        composite.reset(appName: meeting.pattern.appName)
        XCTAssertNil(composite.checkOnce(), "the reset must have reached the mic strategy's cooldown")
    }

    func testLivenessIsPerStrategyOr() throws {
        let mic = micDetector()
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        let meeting = try XCTUnwrap(composite.checkOnce())
        XCTAssertTrue(composite.isMeetingActive(meeting))
        mic.processProvider = { [] }
        XCTAssertFalse(composite.isMeetingActive(meeting))
    }

    // MARK: - A meeting waiting for consent must not shadow one that can start

    /// Reports a fixed meeting (or none) and counts its polls.
    private final class StubDetector: MeetingDetecting {
        let meeting: DetectedMeeting?
        private(set) var polls = 0
        init(_ meeting: DetectedMeeting?) {
            self.meeting = meeting
        }

        func checkOnce() -> DetectedMeeting? {
            polls += 1
            return meeting
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            meeting != nil
        }

        func reset(appName _: String?) {}
    }

    private func meeting(appName: String, requiresConsent: Bool) -> DetectedMeeting {
        DetectedMeeting(
            pattern: AppMeetingPattern(
                appName: appName, ownerNames: [appName], meetingPatterns: [],
                requiresRecordingConsent: requiresConsent,
            ),
            windowTitle: "\(appName) Call",
            ownerName: appName,
            windowPID: 77,
        )
    }

    func testMeetingThatNeedsNoConsentWinsOverOneWaitingForConsent() {
        // A parked browser call is skipped by the loop on every poll.
        let browser = StubDetector(meeting(appName: "Fjordfox", requiresConsent: true))
        let mic = StubDetector(meeting(appName: "WeChat", requiresConsent: false))
        let composite = CompositeMeetingDetector([browser, mic])
        XCTAssertEqual(composite.checkOnce()?.pattern.appName, "WeChat")
    }

    func testMeetingWaitingForConsentIsStillReportedWhenItIsTheOnlyOne() {
        let browser = StubDetector(meeting(appName: "Fjordfox", requiresConsent: true))
        let composite = CompositeMeetingDetector([browser, StubDetector(nil)])
        XCTAssertEqual(composite.checkOnce()?.pattern.appName, "Fjordfox")
    }

    func testEveryStrategyIsPolledEachRound() {
        // Confirmation counters count consecutive polls, so a strategy that is
        // skipped on rounds an earlier one reports something would confirm late.
        let first = StubDetector(meeting(appName: "Microsoft Teams", requiresConsent: false))
        let second = StubDetector(nil)
        let composite = CompositeMeetingDetector([first, second])
        _ = composite.checkOnce()
        _ = composite.checkOnce()
        XCTAssertEqual(second.polls, 2)
    }

    // MARK: - Call IDs (issue #765)

    private let teamsMeeting = DetectedMeeting(
        pattern: .teams, windowTitle: "Call", ownerName: "MSTeams", windowPID: 55,
    )

    func testCallIDsComeFromTheStrategyThatCanIdentifyCalls() {
        let assertions = assertionDetector(active: true)
        assertions.assertionProvider = { PowerAssertionFixture.teamsCall(7, 8, pid: 55) }
        let composite = CompositeMeetingDetector([assertions, micDetector()])
        XCTAssertEqual(composite.activeCalls(teamsMeeting), .ids(["7", "8"]))
    }

    func testCallIDsAreUnknownWhenNoStrategyCanIdentifyCalls() {
        let composite = CompositeMeetingDetector([micDetector()])
        XCTAssertEqual(composite.activeCalls(teamsMeeting), .unidentified)
    }
}
