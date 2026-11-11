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
            flushLiveTranscriptionAfterRecording()
        }
    }

    /// ASR retention must cover the buffered caption tail after recording stops.
    /// A count also covers overlapping stop/quick-restart flush tasks.
    func flushLiveTranscriptionAfterRecording() {
        captionFlushesInFlight += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.captionFlushesInFlight -= 1 }
            await self.liveTranscription.flush()
        }
    }
}
