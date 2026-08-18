import Foundation
@testable import MeetingTranscriber

/// A meeting for tests that need one but do not care what it is.
func makeTestMeeting(pid: pid_t = 4242) -> DetectedMeeting {
    DetectedMeeting(
        pattern: AppMeetingPattern(
            appName: "Test App",
            ownerNames: ["TestApp"],
            meetingPatterns: [#"^Meeting:.*"#],
            idlePatterns: [#"^Test App$"#],
        ),
        windowTitle: "Meeting: Sprint",
        ownerName: "TestApp",
        windowPID: pid,
    )
}

/// Reports one meeting forever, so a started `WatchLoop` enters `handleMeeting`
/// and stays there. `makeSilentDetector`'s opposite, and the counterpart to
/// `ImmediatelyInactiveDetector` below. Immutable, which keeps it Sendable-safe.
final class FixedMeetingDetector: MeetingDetecting {
    private let meeting: DetectedMeeting

    init(_ meeting: DetectedMeeting = makeTestMeeting()) {
        self.meeting = meeting
    }

    func checkOnce() -> DetectedMeeting? {
        meeting
    }

    func isMeetingActive(_: DetectedMeeting) -> Bool {
        true
    }

    func reset(appName _: String?) {}
}

extension HealthCheckResult {
    /// Every permission granted and working. The seed for tests that assert a
    /// recording starts, so nothing they measure depends on the runner's TCC
    /// state — `makeTestWatchLoop` installs the same verdict for the same reason.
    static let allHealthy = Self(screenRecording: .healthy, microphone: .healthy)
}
