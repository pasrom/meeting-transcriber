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

    func testLivenessIsPerStrategyOr() throws {
        let mic = micDetector()
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        let meeting = try XCTUnwrap(composite.checkOnce())
        XCTAssertTrue(composite.isMeetingActive(meeting))
        mic.processProvider = { [] }
        XCTAssertFalse(composite.isMeetingActive(meeting))
    }
}
