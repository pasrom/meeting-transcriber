import Foundation

/// The recorder factory `WatchLoop` is handed: a fresh recorder per recording,
/// configured for it.
///
/// Its own file because `WatchingController.swift` sits at the line cap; the
/// members it reaches into (`makeRecorder`, `liveTranscription`) are internal
/// rather than private for exactly that.
@MainActor
extension WatchingController {
    /// Build the `recorderFactory` closure for `WatchLoop`. Returns a fresh
    /// `DualSourceRecorder` on each invocation; when live captions are eligible,
    /// the coordinator installs mic + app live sinks that pipe captured buffers to
    /// the `LiveTranscriptionController`. `async` so the coordinator can await the
    /// prior recording's stop-time flush before reusing a kept EOU session.
    func makeRecorderFactory() -> @MainActor () async -> any RecordingProvider {
        { [weak self, makeRecorder] in
            let recorder = makeRecorder()
            // Live captions tap the concrete recorder's buffer sinks, so this is
            // the production recorder or nothing. An injected double has no
            // sinks and needs none: captions are off in every test that uses one.
            if let dualSource = recorder as? DualSourceRecorder {
                await self?.liveTranscription.attachSinks(to: dualSource)
            }
            return recorder
        }
    }
}
