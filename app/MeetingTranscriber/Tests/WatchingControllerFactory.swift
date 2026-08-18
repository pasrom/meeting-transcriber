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
    /// - Parameter permissionHealth: seeds the health the controller hands to
    ///   each loop it builds. Pass one whenever a test asserts that a start
    ///   *succeeds*: nil leaves it unprobed, and the loop then runs a live TCC
    ///   check whose microphone arm opens the real input device. Under
    ///   `swift test --parallel` that is several forked processes probing the
    ///   HAL at once, and it intermittently comes back denied, which the start
    ///   then correctly refuses.
    /// - Parameter makeRecorder: defaults to a `MockRecorder` carrying a mix
    ///   path, so a stop through it takes the success path. Nothing built here
    ///   touches real audio hardware, because `DualSourceRecorder` writes into
    ///   `AppPaths.recordingsDir` — the production staging directory that orphan
    ///   recovery scans. Real `.micOnly` capture is the live lane's job, not a
    ///   unit test's; see the `e2e-architecture` skill.
    static func make(
        logDir: URL,
        ensureMicAccess: @escaping () async -> Bool = { true },
        requestScreenRecording: @escaping () -> Void = {},
        requestAccessibility: @escaping () -> Void = {},
        watchTeams: Bool = true,
        noMic: Bool = false,
        permissionHealth: HealthCheckResult? = nil,
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
        makeDetector: @escaping () -> any MeetingDetecting = { makeSilentDetector() },
        makeRecorder: @escaping @MainActor () -> any RecordingProvider = { makeMockRecorder() },
    ) -> WatchingController {
        // Own defaults suite, like `makeRPCTestState`: `AppSettings()` on
        // `.standard` writes into the test host's real preferences, and
        // `performManualRecording` reads `recordOnly` and the output directory
        // back out of that same domain — a value left behind by another test
        // would send these down the record-only path and into a user folder.
        let suite = "WatchingControllerFactory-\(getpid())-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
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
        if let permissionHealth { permissions.handle(permissionHealth) }
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
            makeRecorder: makeRecorder,
        )
    }
}
