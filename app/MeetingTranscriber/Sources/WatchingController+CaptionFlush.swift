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
    /// With a live transcript open, held in `transcriptEnds` so a quit waits for it:
    /// the flush writes the recording's last lines and starts its `end`. Without one
    /// it writes nothing to disk, and a quit does not wait for it.
    func flushLiveTranscriptionAfterRecording() {
        captionFlushesInFlight += 1
        let flush: @MainActor () async -> Void = { [weak self] in
            guard let self else { return }
            defer { self.captionFlushesInFlight -= 1 }
            await self.liveTranscription.flush()
        }
        if liveTranscription.hasOpenTranscriptFile {
            liveTranscription.transcriptEnds.track(flush)
        } else {
            Task { await flush() }
        }
    }
}
