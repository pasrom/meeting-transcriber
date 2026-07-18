@testable import MeetingTranscriber
import XCTest

final class AppMeetingPatternTests: XCTestCase {
    // MARK: - forAppName Lookup

    func testForAppNameReturnsTeams() {
        let pattern = AppMeetingPattern.forAppName("Microsoft Teams")
        XCTAssertEqual(pattern?.appName, "Microsoft Teams")
    }

    func testForAppNameCaseInsensitive() {
        let pattern = AppMeetingPattern.forAppName("microsoft teams")
        XCTAssertEqual(pattern?.appName, "Microsoft Teams")
    }

    func testForAppNameReturnsNilForUnknown() {
        XCTAssertNil(AppMeetingPattern.forAppName("Unknown App"))
    }

    // MARK: - All Patterns

    func testAllPatternsCount() {
        XCTAssertEqual(AppMeetingPattern.all.count, 5)
    }

    // MARK: - Chrome Browser Pattern (issue #503)

    func testForAppNameReturnsChromeBrowser() {
        let pattern = AppMeetingPattern.forAppName("Google Chrome")
        XCTAssertEqual(pattern?.appName, "Google Chrome")
        XCTAssertTrue(pattern?.ownerNames.contains("Google Chrome") ?? false)
    }

    func testChromeBrowserRequiresRecordingConsent() {
        XCTAssertTrue(AppMeetingPattern.chromeBrowser.requiresRecordingConsent)
    }

    func testNativePatternsDoNotRequireRecordingConsent() {
        // Native desktop meeting apps keep their auto-start behaviour; only
        // browser meetings gate behind a prompt.
        XCTAssertFalse(AppMeetingPattern.teams.requiresRecordingConsent)
        XCTAssertFalse(AppMeetingPattern.zoom.requiresRecordingConsent)
        XCTAssertFalse(AppMeetingPattern.webex.requiresRecordingConsent)
        XCTAssertFalse(AppMeetingPattern.simulator.requiresRecordingConsent)
    }

    // MARK: - Simulator Pattern

    func testSimulatorPattern() {
        let sim = AppMeetingPattern.simulator
        XCTAssertEqual(sim.appName, "MeetingSimulator")
        XCTAssertEqual(sim.minWindowWidth, 100)
        XCTAssertEqual(sim.minWindowHeight, 100)
    }

    // MARK: - Teams Pattern

    func testTeamsHasMeetingPatterns() {
        XCTAssertFalse(AppMeetingPattern.teams.meetingPatterns.isEmpty)
    }

    func testTeamsHasIdlePatterns() {
        XCTAssertFalse(AppMeetingPattern.teams.idlePatterns.isEmpty)
    }

    func testDefaultMinWindowDimensions() {
        XCTAssertEqual(AppMeetingPattern.teams.minWindowWidth, 200)
        XCTAssertEqual(AppMeetingPattern.teams.minWindowHeight, 200)
    }

    // MARK: - Zoom Pattern

    func testZoomOwnerNames() {
        XCTAssertTrue(AppMeetingPattern.zoom.ownerNames.contains("zoom.us"))
    }

    // MARK: - Webex Pattern

    func testWebexOwnerNames() {
        XCTAssertTrue(AppMeetingPattern.webex.ownerNames.contains("Webex"))
    }
}
