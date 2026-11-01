import Foundation
@testable import MeetingTranscriber
import XCTest

/// Builds a `WatchingController` wired to real (but inert) sibling controllers
/// and the supplied seams. The pipeline gets a queue on an isolated `logDir` so
/// `rebuild()` touches no production path, and the default detector never
/// matches a window so no recording starts.
///
/// Its own file because `WatchingControllerTests` sits at the 600-line cap, and
/// because a second suite now needs the same wiring.
///
/// An `XCTestCase` extension rather than a free-standing enum so it can reach
/// the test-case lifecycle; the defaults suite it needs is handled below.
@MainActor
extension XCTestCase {
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
    /// - Parameter notifier: pass one to assert on the refusals this controller
    ///   reports. A silent refusal is the failure mode several of its guards
    ///   exist to avoid, so "was the user told" is part of the behaviour, not a
    ///   detail. Defaults to a fresh spy when a test does not care.
    ///   Any `AppNotifying` spy works; a test that needs more than titles and
    ///   bodies brings its own.
    /// - Parameter channelFaultWindow: the channel-health window. Zero (the
    ///   default) lets the first tick decide; see
    ///   `WatchingControllerChannelFaultTests` for when that is not enough.
    func makeWatchingController(
        logDir: URL,
        notifier: any AppNotifying = RecordingNotifier(),
        ensureMicAccess: @escaping () async -> Bool = { true },
        requestScreenRecording: @escaping () -> Void = {},
        requestAccessibility: @escaping () -> Void = {},
        watchTeams: Bool = true,
        noMic: Bool = false,
        permissionHealth: HealthCheckResult? = nil,
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
        joinClock: any Clock<Duration> = ContinuousClock(),
        channelFaultWindow: TimeInterval = 0,
        makeDetector: @escaping () -> any MeetingDetecting = { makeSilentDetector() },
        makeRecorder: @escaping @MainActor () -> any RecordingProvider = { makeMockRecorder() },
    ) -> WatchingController {
        // Own defaults suite, like `makeRPCTestState`: `AppSettings()` on
        // `.standard` writes into the test host's real preferences, and
        // `performManualRecording` reads `recordOnly` and the output directory
        // back out of that same domain — a value left behind by another test
        // would send these down the record-only path and into a user folder.
        // One suite per test PROCESS, not per call, reset on every call; its
        // file lives in the process's `DefaultsSuite` folder, which a later run
        // deletes.
        let suite = "WatchingControllerFactory-\(getpid())"
        // Start from a clean domain so one test never reads what another wrote.
        // Note for a future caller: this resets the whole process-wide suite, so
        // two controllers built inside ONE test method would have the second
        // call wipe the first's persisted values. Their in-memory `AppSettings`
        // survive, since it snapshots at init, but do not build two and expect
        // both to persist.
        DefaultsSuite.remove(suite)
        // Never fall back to `.standard`: that is the host's real domain.
        guard let defaults = DefaultsSuite.open(suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        let settings = AppSettings(
            defaults: defaults,
            // The default output folder is the one path from this factory into a
            // real user folder that the suite above does not close: output goes
            // to `~/Downloads/MeetingTranscriber` whenever no folder is chosen
            // or the chosen one cannot be reached. Point it into the test's own
            // directory so a record-only stop can never land there.
            defaultOutputDir: logDir.appendingPathComponent("output", isDirectory: true),
        )
        settings.watchTeams = watchTeams
        settings.noMic = noMic
        let pipeline = PipelineController(
            settings: settings,
            notifier: notifier,
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: logDir),
        )
        let channelHealth = ChannelHealthController(
            notifier: notifier,
            debounceSeconds: { channelFaultWindow },
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
            joinClock: joinClock,
            makeDetector: makeDetector,
            makeRecorder: makeRecorder,
        )
    }
}
