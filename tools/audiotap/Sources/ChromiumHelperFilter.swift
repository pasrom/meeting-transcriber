import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "ChromiumHelperFilter")

/// Keeps a Chromium-based app's audio service in the tap set and drops its
/// other helpers (issue #791).
///
/// A Chromium browser (Chrome, Brave, Edge, Comet) or Electron app renders
/// every output stream in one utility process, `--utility-sub-type=
/// audio.mojom.AudioService`. The bundle-rooted enumeration also returns the
/// helpers that merely talked to CoreAudio, and on macOS 14.6.1 the reporter
/// of #791 measured that a `stereoMixdownOfProcesses` tap over the audio
/// service *and* the video-capture service (`video_capture.mojom.
/// VideoCaptureService`) never runs its first IO cycle: tap, aggregate and
/// `AudioDeviceStart` all succeed, the aggregate stays not running, the app
/// track stays empty. The same tap over the audio service alone, or with the
/// browser root, delivers. Which HAL interaction stalls the aggregate is not
/// known, so the selection is an allow-list rather than a deny-list of the
/// one helper measured: every `--type=` child other than the audio service
/// goes, including ones not yet seen to stall. What that trades away: a child
/// that renders through a native add-on instead of the audio service (an
/// Electron app with node integration could) would be dropped too; no such
/// app has been measured.
///
/// Rejected: selecting by `kAudioProcessPropertyIsRunningOutput`. It says
/// whether the process has an output stream running at the moment of the read
/// (`ProcessOutputState`; a stream rendering zeroes still counts), and a
/// Chromium audio service has one only while something plays. A tap built
/// before the far end's audio has started would read false on the audio
/// service itself and drop the one process that matters.
///
/// The filter only acts when it has found an audio service, so an app with no
/// such helper (a native app, a WebKit app, a Chromium with in-process audio)
/// keeps its set untouched. A process whose arguments cannot be read has no
/// `--type=` either and is kept as well.
public enum ChromiumHelperFilter {
    /// What a process's arguments say it is, as far as this filter cares.
    enum Role {
        /// No `--type=` argument: the browser or app itself, any non-Chromium
        /// process, or an argv the kernel would not give out.
        case notAChild
        /// `--type=utility --utility-sub-type=audio.mojom.AudioService`.
        case audioService
        /// Any other Chromium child: renderer, GPU, network, video capture.
        case otherChild
    }

    static func role(of arguments: [String]) -> Role {
        guard let type = value(of: "--type", in: arguments) else { return .notAChild }
        if type == "utility",
           value(of: "--utility-sub-type", in: arguments) == "audio.mojom.AudioService" {
            return .audioService
        }
        return .otherChild
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        let prefix = flag + "="
        guard let match = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(match.dropFirst(prefix.count))
    }

    /// `pids` with every Chromium child other than the audio service removed,
    /// in the original order, plus what was removed. Unchanged when no audio
    /// service is among them.
    static func select(
        _ pids: [pid_t],
        arguments: (pid_t) -> [String],
    ) -> (kept: [pid_t], dropped: [pid_t]) {
        let roles = pids.map { (pid: $0, role: role(of: arguments($0))) }
        guard roles.contains(where: { $0.role == .audioService }) else {
            return (kept: pids, dropped: [])
        }
        return (
            kept: roles.filter { $0.role != .otherChild }.map(\.pid),
            dropped: roles.filter { $0.role == .otherChild }.map(\.pid),
        )
    }

    /// The live form of `select`, reading each process's arguments from the
    /// kernel and logging what it drops at the same level as the tap summary,
    /// so a silent-track report shows which helpers the tap did not cover.
    public static func audioRelevantPIDs(_ pids: [pid_t]) -> [pid_t] {
        let selection = select(pids, arguments: ProcessArguments.live)
        if !selection.dropped.isEmpty {
            logger.info(
                "App audio tap: tapping the Chromium audio service, leaving out \(selection.dropped.count, privacy: .public) other helper(s) [\(pidSummary(selection.dropped), privacy: .public)]",
            )
        }
        return selection.kept
    }
}
