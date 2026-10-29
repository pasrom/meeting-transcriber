@testable import MeetingTranscriber
import XCTest

/// `PowerAssertionDetector.activeCalls`: which assertions identify the call
/// a meeting app is in (issue #765).
final class PowerAssertionDetectorCallIDTests: XCTestCase {
    private func meeting(_ pattern: AppMeetingPattern) -> DetectedMeeting {
        DetectedMeeting(pattern: pattern, windowTitle: "Call", ownerName: "", windowPID: 1234)
    }

    func testTeamsReportsTheIDsOfItsCallAssertions() {
        let detector = PowerAssertionDetector()
        // The WebView's audio assertion is not a call and must not count.
        let webViewAudio = PowerAssertionFixture.identified(
            PowerAssertionFixture.typedAssertions([
                (1500, "Microsoft Teams WebView", "Playing audio", "NoIdleSleepAssertion"),
            ]),
            id: 103,
        )
        detector.assertionProvider = {
            PowerAssertionFixture.teamsCall(101, 102).merging(webViewAudio) { current, _ in current }
        }
        XCTAssertEqual(detector.activeCalls(meeting(.teams)), .ids(["101", "102"]))
    }

    func testTeamsWithoutACallReportsNoIDs() {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = { [:] }
        XCTAssertEqual(detector.activeCalls(meeting(.teams)), .ids([]))
    }

    func testAnAssertionWithoutAnIDMakesTheAnswerUnknown() {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = { PowerAssertionFixture.teamsCall(101, nil) }
        XCTAssertEqual(detector.activeCalls(meeting(.teams)), .unidentified)
    }

    func testAppsNotMeasuredToHaveOneAssertionPerCallReportUnknown() {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = {
            PowerAssertionFixture.identified(PowerAssertionFixture.assertions((77, "zoom.us", "Zoom meeting")), id: 5)
        }
        XCTAssertEqual(detector.activeCalls(meeting(.zoom)), .unidentified)
    }
}
