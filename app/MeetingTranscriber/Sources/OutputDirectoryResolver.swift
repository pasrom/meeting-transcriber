import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OutputDirectoryResolver")

/// The folder a recording's output goes to, decided where that decision is
/// actually made: when a pipeline queue is built (`PipelineController.makeQueue`
/// captures the folder by value for every job the queue will run) and when a
/// record-only recording is written (`WatchingController`'s destination
/// closure, once per recording). Nowhere else: a view body and the watch loop's
/// poll read the pure `AppSettings.effectiveOutputDir` and must keep doing so,
/// because a read that notifies would fire on every render or tick.
///
/// Why it exists: when the chosen folder's bookmark stops resolving (an
/// unplugged drive, an unmounted share, a deleted folder), `effectiveOutputDir`
/// quietly yields the default and recordings land in
/// `~/Downloads/MeetingTranscriber` with nothing saying so. The fallback is
/// right, a recording must never be blocked or lost over a missing folder, so
/// this keeps it and adds the telling.
///
/// Once per episode, not once per decision: the first fallback for a given
/// bookmark notifies, later ones stay quiet until the folder resolves again or
/// the user picks a different one. Same shape as `PermissionsController.handle`,
/// which re-notifies only on a changed problem set; `NotificationManager` has
/// no keyed dedup of its own. Owned by `PipelineController` and shared with
/// `WatchingController` so both seams share one memory.
///
/// Outside `AppSettings` because a settings model must not own notifications;
/// the notifier is injected the way `WatchLoop` takes it for record-only write
/// failures.
@MainActor
final class OutputDirectoryResolver {
    static let unavailableTitle = "Output folder unavailable"

    private let settings: AppSettings
    private let notifier: any AppNotifying
    /// The bookmark the last notification was about; nil once the folder
    /// resolved again, so the next unavailability is news again.
    private var reportedUnavailableBookmark: Data?

    init(settings: AppSettings, notifier: any AppNotifying) {
        self.settings = settings
        self.notifier = notifier
    }

    /// The directory to write into now. Never nil and never a refusal: a
    /// folder that cannot be reached is reported, and the default is returned.
    func resolve() -> URL {
        switch settings.outputDirectoryResolution {
        case let .defaultLocation(url), let .custom(url):
            reportedUnavailableBookmark = nil
            return url

        case let .fallback(url, configuredPath):
            reportIfNew(configuredPath: configuredPath, fallback: url)
            return url
        }
    }

    private func reportIfNew(configuredPath: String?, fallback: URL) {
        let bookmark = settings.customOutputDirBookmark
        guard bookmark != reportedUnavailableBookmark else { return }
        reportedUnavailableBookmark = bookmark

        let home = FileManager.default.homeDirectoryForCurrentUser
        let chosen = configuredPath.map { path in
            OutputSettingsLogic.displayPath(for: URL(fileURLWithPath: path), home: home)
        } ?? "The chosen output folder"
        let standIn = OutputSettingsLogic.displayPath(for: fallback, home: home)
        // Paths are the user's own folders, shown in Settings anyway; the log
        // line stays path-free because os_log lines can leave the machine.
        logger.error("Chosen output folder cannot be reached; output goes to the default folder instead")
        notifier.notify(
            title: Self.unavailableTitle,
            body: "\(chosen) cannot be reached right now. Recordings and protocols are going to \(standIn) instead. "
                + "Reconnect it, or choose another folder in Settings.",
        )
    }
}
