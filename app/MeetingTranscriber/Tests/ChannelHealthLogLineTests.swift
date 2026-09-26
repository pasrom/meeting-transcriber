import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The diagnostics lines are the only record of what the channel-health
/// monitors decided, so what they say has to be exact where a field diagnosis
/// depends on it: "never" against a number, which fault on which channel, and
/// "none" when no verdict was reached.
final class ChannelHealthLogLineTests: XCTestCase {
    func testAChannelThatNeverDeliveredSaysNeverRatherThanAnAge() {
        let line = ChannelHealthController.describe(ChannelSignalAges.unknown)

        XCTAssertEqual(line, "lastBuffer=never lastEnergy=never")
    }

    func testAChannelThatStoppedCarriesItsAges() {
        let ages = ChannelSignalAges(secondsSinceLastBuffer: 2891.34, secondsSinceLastEnergy: nil)

        XCTAssertEqual(ChannelHealthController.describe(ages), "lastBuffer=2891.3s lastEnergy=never")
    }

    func testTheFaultLineNamesTheChannelTheFaultAndTheEvidence() {
        let line = ChannelHealthController.faultLogLine(
            channel: .mic, fault: .noBuffers, ages: .unknown, elapsed: 90.04, window: 90,
        )

        XCTAssertEqual(
            line,
            "Channel fault: channel=mic fault=noBuffers lastBuffer=never lastEnergy=never "
                + "elapsed=90.0s window=90.0s, notifying",
        )
    }

    func testTheStopLineSaysNoneWhenNoVerdictWasReached() {
        let line = ChannelHealthController.stopLogLine(
            micFault: nil, appFault: .digitalSilence, recordingSilent: false, micAges: .unknown,
            appAges: ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 12),
        )

        XCTAssertEqual(
            line,
            "Channel health monitoring stopped: micFault=none appFault=digitalSilence recordingSilent=false, "
                + "mic lastBuffer=never lastEnergy=never, app lastBuffer=0.0s lastEnergy=12.0s",
        )
    }

    func testTheSilentRecordingRecoveryLineCarriesTheLevelsThatEndedIt() {
        XCTAssertEqual(
            ChannelHealthController.silentRecordingRecoveredLogLine(micDBFS: -20, appDBFS: -115.24),
            "Silent recording recovered (mic=-20.0 dBFS app=-115.2 dBFS)",
        )
    }

    func testTheIgnoredRestartLineNamesBothTopologies() {
        XCTAssertEqual(
            ChannelHealthController.restartIgnoredLogLine(channels: .micOnly, previous: .micAndApp),
            "Channel health monitoring already running: channels=mic (was mic+app)",
        )
    }

    func testTheStartLineNamesTheOpenedChannels() {
        XCTAssertEqual(
            ChannelHealthController.startLogLine(channels: .micOnly, window: 90),
            "Channel health monitoring started: channels=mic window=90.0s",
        )
        XCTAssertEqual(ChannelHealthController.describe(CapturedChannels.micAndApp), "mic+app")
        XCTAssertEqual(ChannelHealthController.describe(CapturedChannels.appOnly), "app")
    }

    /// The raw values are what the fault line logs, so a renamed case must fail
    /// here rather than change the log text unnoticed.
    func testTheChannelNamesTheLogUsesArePinned() {
        XCTAssertEqual(AudioChannel.mic.rawValue, "mic")
        XCTAssertEqual(AudioChannel.app.rawValue, "app")
    }

    func testTheSilentRecordingLineCarriesBothLevels() {
        XCTAssertEqual(
            ChannelHealthController.silentRecordingLogLine(micDBFS: -120, appDBFS: -115.24, window: 90),
            "Silent recording: both channels silent for 90.0s (mic=-120.0 dBFS app=-115.2 dBFS), notifying",
        )
    }
}
