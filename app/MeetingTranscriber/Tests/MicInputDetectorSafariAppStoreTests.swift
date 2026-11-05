@testable import MeetingTranscriber
import XCTest

#if APPSTORE
    /// The App Store build cannot resolve responsibility, so Safari can never
    /// be detected there: the browser toggle must not switch on the mic
    /// channel for it, and Settings must not promise it.
    final class MicInputDetectorSafariAppStoreTests: XCTestCase {
        func testBrowserToggleAddsNoSafariPatterns() {
            XCTAssertTrue(MicInputDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName]).isEmpty)
        }

        func testBrowserToggleAloneDoesNotEnumerateAudioProcesses() {
            let detector = MicInputDetector(
                patterns: MicInputDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName]),
                confirmationCount: 1,
            )
            var providerCalls = 0
            detector.processProvider = {
                providerCalls += 1
                return []
            }
            XCTAssertNil(detector.checkOnce())
            XCTAssertEqual(providerCalls, 0)
        }

        func testCaptionDoesNotPromiseSafari() {
            XCTAssertFalse(GeneralSettingsView.browserMeetingsCaption.contains("Safari"))
        }
    }
#endif
