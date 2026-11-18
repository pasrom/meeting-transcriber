import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "ChromiumHelperFilter")

/// Keeps a Chromium-based app's audio processes in the tap set (issue #791).
///
/// A Chromium browser (Chrome, Brave, Edge, Comet) or Electron app
/// usually renders through a utility process, `--utility-sub-type=
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
/// goes unless the caller opts in to keeping renderers. Discord needs that
/// opt-in: Core Audio reports its renderer as the output owner while its
/// separate Chromium audio service is running.
///
/// Rejected: selecting by `kAudioProcessPropertyIsRunningOutput`. It says
/// whether the process has an output stream running at the moment of the read
/// (`ProcessOutputState`; a stream rendering zeroes still counts), and a
/// Chromium audio service has one only while something plays. A tap built
/// before the far end's audio has started would read false on the audio
/// service itself and drop the one process that matters.
///
/// The filter acts only after finding an audio service or an opted-in renderer.
/// Native and WebKit app process sets pass through unchanged. A process whose arguments cannot be read has no
/// `--type=` either and is kept as well.
public enum ChromiumHelperFilter {
    /// What a process's arguments say it is, as far as this filter cares.
    enum Role {
        /// No `--type=` argument: the browser or app itself, any non-Chromium
        /// process, or an argv the kernel would not give out.
        case notAChild
        /// `--type=utility --utility-sub-type=audio.mojom.AudioService`.
        case audioService
        /// Discord can render voice through this process.
        case renderer
        /// Other Chromium children, such as GPU, network, video capture.
        case otherChild
    }

    static func role(of arguments: [String]) -> Role {
        guard let type = value(of: "--type", in: arguments) else { return .notAChild }
        if type == "utility",
           value(of: "--utility-sub-type", in: arguments) == "audio.mojom.AudioService" {
            return .audioService
        }
        return type == "renderer" ? .renderer : .otherChild
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        let prefix = flag + "="
        guard let match = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(match.dropFirst(prefix.count))
    }

    /// Retain the root, audio service, and any opted-in renderers, preserving order.
    static func select(
        _ pids: [pid_t],
        includeRenderers: Bool = false,
        arguments: (pid_t) -> [String],
    ) -> (kept: [pid_t], dropped: [pid_t]) {
        let roles = pids.map { (pid: $0, role: role(of: arguments($0))) }
        func isAudioRole(_ role: Role) -> Bool {
            role == .audioService || (includeRenderers && role == .renderer)
        }
        guard roles.contains(where: { isAudioRole($0.role) }) else {
            return (kept: pids, dropped: [])
        }
        var kept: [pid_t] = []
        var dropped: [pid_t] = []
        for (pid, role) in roles {
            if role == .notAChild || isAudioRole(role) {
                kept.append(pid)
            } else {
                dropped.append(pid)
            }
        }
        return (kept, dropped)
    }

    /// The live form of `select`, reading each process's arguments from the kernel.
    public static func audioRelevantPIDs(_ pids: [pid_t], includeRenderers: Bool = false) -> [pid_t] {
        let selection = select(pids, includeRenderers: includeRenderers, arguments: ProcessArguments.live)
        if !selection.dropped.isEmpty {
            logger.info(
                "App audio tap: leaving out \(selection.dropped.count, privacy: .public) non-audio Chromium helper(s) [\(pidSummary(selection.dropped), privacy: .public)]",
            )
        }
        return selection.kept
    }
}
