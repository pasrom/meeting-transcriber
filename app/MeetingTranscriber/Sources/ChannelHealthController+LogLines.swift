import AudioTapLib
import Foundation

/// The diagnostics lines `ChannelHealthController` writes, built here as pure
/// strings so their content is testable and so the controller file stays under
/// the length cap.
///
/// Before these existed the controller logged nothing at all, so a field report
/// of "no notification was shown" could not be told apart from "no verdict was
/// ever reached", "monitoring never started" or "the notification was posted
/// and not seen". The lines are written unconditionally and reach the persisted
/// diagnostics log, so they carry only what the monitors themselves decide on:
/// channel names, fault kinds, ages, levels and the window. Never a device name,
/// a device UID or a meeting title. Written through `DiagnosticsLogging`, whose
/// production sink explains the level; every line is bounded per recording or
/// per silence episode, never per tick.
extension ChannelHealthController {
    /// "mic+app", "mic" or "app": the channels the recording opened. "none"
    /// only completes the switch: `CapturedChannels` cannot be constructed
    /// with neither channel, so no recording reaches it.
    nonisolated static func describe(_ channels: CapturedChannels) -> String {
        switch (channels.mic, channels.app) {
        case (true, true): "mic+app"
        case (true, false): "mic"
        case (false, true): "app"
        case (false, false): "none"
        }
    }

    /// Both ages of one channel. `never` is kept distinct from a number on
    /// purpose: a channel that never delivered and one that stopped are
    /// different failures (see `ChannelFault.noBuffers`).
    nonisolated static func describe(_ ages: ChannelSignalAges) -> String {
        "lastBuffer=\(seconds(ages.secondsSinceLastBuffer)) lastEnergy=\(seconds(ages.secondsSinceLastEnergy))"
    }

    nonisolated static func startLogLine(channels: CapturedChannels, window: TimeInterval) -> String {
        "Channel health monitoring started: channels=\(describe(channels)) window=\(seconds(window))"
    }

    nonisolated static func firstTickLogLine(micAges: ChannelSignalAges, appAges: ChannelSignalAges) -> String {
        "Channel health first tick: mic \(describe(micAges)), app \(describe(appAges))"
    }

    /// The verdict that precedes a "Capture Channel Silent" or "Capture Channel
    /// Lost" notification, with the evidence it was reached on.
    nonisolated static func faultLogLine(
        channel: AudioChannel,
        fault: ChannelFault,
        ages: ChannelSignalAges,
        elapsed: TimeInterval,
        window: TimeInterval,
    ) -> String {
        "Channel fault: channel=\(channel.rawValue) fault=\(fault.rawValue) \(describe(ages)) "
            + "elapsed=\(seconds(elapsed)) window=\(seconds(window)), notifying"
    }

    /// The verdict that precedes "Recording Appears Silent". Levels rather than
    /// ages, because that monitor still decides from levels.
    nonisolated static func silentRecordingLogLine(micDBFS: Double, appDBFS: Double, window: TimeInterval) -> String {
        "Silent recording: both channels silent for \(seconds(window)) "
            + "(mic=\(dBFS(micDBFS)) app=\(dBFS(appDBFS))), notifying"
    }

    /// What the recording ended with, including "no fault", which is the line
    /// that says a verdict was never reached rather than reached and lost, and
    /// whether a silent-recording episode was still open, which is the end
    /// marker for a "Silent recording" line that never saw a recovery.
    nonisolated static func stopLogLine(
        micFault: ChannelFault?,
        appFault: ChannelFault?,
        recordingSilent: Bool,
        micAges: ChannelSignalAges,
        appAges: ChannelSignalAges,
    ) -> String {
        "Channel health monitoring stopped: micFault=\(micFault?.rawValue ?? "none") "
            + "appFault=\(appFault?.rawValue ?? "none") recordingSilent=\(recordingSilent), "
            + "mic \(describe(micAges)), app \(describe(appAges))"
    }

    /// The stop line for this controller's current state.
    var stopLogLine: String {
        Self.stopLogLine(
            micFault: micFault, appFault: appFault, recordingSilent: recordingSilentActive,
            micAges: micAges, appAges: appAges,
        )
    }

    /// The end of a "Silent recording" episode, with the levels that ended it.
    nonisolated static func silentRecordingRecoveredLogLine(micDBFS: Double, appDBFS: Double) -> String {
        "Silent recording recovered (mic=\(dBFS(micDBFS)) app=\(dBFS(appDBFS)))"
    }

    /// A start while monitoring was already running. It is otherwise ignored,
    /// but it does replace the topology the monitors judge against, which is
    /// what this line records.
    nonisolated static func restartIgnoredLogLine(channels: CapturedChannels, previous: CapturedChannels) -> String {
        "Channel health monitoring already running: channels=\(describe(channels)) (was \(describe(previous)))"
    }

    nonisolated private static func seconds(_ value: Double?) -> String {
        guard let value else { return "never" }
        return String(format: "%.1fs", value)
    }

    nonisolated private static func dBFS(_ value: Double) -> String {
        String(format: "%.1f dBFS", value)
    }
}
