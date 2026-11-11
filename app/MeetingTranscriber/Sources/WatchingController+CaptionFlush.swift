import Foundation

/// Starting the live-caption flush when a recording ends. Its own file because
/// `WatchingController.swift` sits near the line cap.
@MainActor
extension WatchingController {
    /// Commit the pending caption tail of the recording that just ended. Not
    /// called for a call split: the next call binds its caption feeds in the
    /// same main-actor stretch, and a flush started then would run after that
    /// and retire them.
    func startCaptionFlush() {
        if let captionFlushOverride {
            captionFlushOverride()
        } else {
            Task { @MainActor [weak self] in await self?.liveTranscription.flush() }
        }
    }
}
