import Foundation
@testable import MeetingTranscriber

/// Builds a `WatchingController` wired to real (but inert) sibling controllers
/// and the supplied seams. The pipeline gets a queue on an isolated `logDir` so
/// `rebuild()` touches no production path, and the default detector never
/// matches a window so no recording starts.
///
/// Its own file because `WatchingControllerTests` sits at the 600-line cap, and
/// because a second suite now needs the same wiring.
@MainActor
enum WatchingControllerFactory {
    static func make(
        logDir: URL,
        ensureMicAccess: @escaping () async -> Bool = { true },
        requestScreenRecording: @escaping () -> Void = {},
        requestAccessibility: @escaping () -> Void = {},
        watchTeams: Bool = true,
        noMic: Bool = false,
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
        makeDetector: @escaping () -> any MeetingDetecting = { makeSilentDetector() },
    ) -> WatchingController {
        let settings = AppSettings()
        settings.watchTeams = watchTeams
        settings.noMic = noMic
        let notifier = RecordingNotifier()
        let pipeline = PipelineController(settings: settings, notifier: notifier)
        pipeline.queue = PipelineQueue(logDir: logDir)
        let channelHealth = ChannelHealthController(
            notifier: notifier,
            debounceSeconds: { 0 },
            indicatorEnabled: { false },
        )
        let permissions = PermissionsController(notifier: notifier)
        let liveTranscription = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { false },
            engineSupportsLive: { false },
            verboseDiagnostics: { false },
        )
        return WatchingController(
            settings: settings,
            notifier: notifier,
            pipeline: pipeline,
            channelHealth: channelHealth,
            permissions: permissions,
            liveTranscription: liveTranscription,
            ensureMicAccess: ensureMicAccess,
            requestScreenRecording: requestScreenRecording,
            requestAccessibility: requestAccessibility,
            startJoinTimeout: startJoinTimeout,
            makeDetector: makeDetector,
        )
    }
}
