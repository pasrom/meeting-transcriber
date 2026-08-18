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
    /// Whether this process already swept. The sweep scans a directory with
    /// hundreds of entries, and doing that per call cost 16 s across the suite
    /// against 2.8 s; once per process is enough, since nothing creates these
    /// files but the factory itself.
    nonisolated(unsafe) private static var didSweepFactoryDefaults = false

    /// Remove the preference files of test processes that are gone.
    ///
    /// Exact prefix, and only when the owning pid no longer exists, so a run in
    /// flight keeps its own file — including a `--parallel` sibling, which is
    /// its own process. The pid is the first component after the prefix, which
    /// also matches the older `<pid>-<uuid>` names an earlier per-call version
    /// of this factory left behind.
    /// Whether no process holds this pid.
    ///
    /// `kill(pid, 0) != 0` alone means "not signalable", which is not the same
    /// thing: a live process owned by another user answers `EPERM`, and reading
    /// that as dead would have this delete a file out from under a running one.
    /// Proven reachable by planting a file named after pid 1. Harmless in the
    /// scenarios this factory can actually produce, and still wrong, so the
    /// predicate says what it means.
    private static func processIsGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    static func sweepDeadFactoryDefaults() {
        guard !didSweepFactoryDefaults else { return }
        didSweepFactoryDefaults = true
        let prefix = "WatchingControllerFactory-"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            let stem = name.dropFirst(prefix.count).dropLast(".plist".count)
            guard let owner = pid_t(stem.split(separator: "-").first ?? ""), owner > 0,
                  Self.processIsGone(owner)
            else { continue }
            UserDefaults().removePersistentDomain(forName: String(name.dropLast(".plist".count)))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

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
    func makeWatchingController(
        logDir: URL,
        notifier: RecordingNotifier = RecordingNotifier(),
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
        // One suite per test PROCESS, not per call, and a sweep of the ones
        // dead processes left behind.
        //
        // Isolation is not optional here: this factory writes `noMic` and
        // `watchTeams`, and `performManualRecording` reads `recordOnly` and the
        // output directory back out of the same domain, so a value stranded in
        // `.standard` could send a test into a real user folder. But a suite
        // cannot be un-created: the preferences daemon owns the file's
        // lifecycle and flushes its cached copy back after any removal the test
        // performs. Measured across three attempts (remove domain, then also
        // delete the file, then the full deregistration dance): 39 files
        // survived each time. So the file is treated as reusable and the
        // leftovers are swept by owner instead.
        let suite = "WatchingControllerFactory-\(getpid())"
        Self.sweepDeadFactoryDefaults()
        // Start from a clean domain so one test never reads what another wrote.
        // Note for a future caller: this resets the whole process-wide suite, so
        // two controllers built inside ONE test method would have the second
        // call wipe the first's persisted values. Their in-memory `AppSettings`
        // survive, since it snapshots at init, but do not build two and expect
        // both to persist.
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        settings.watchTeams = watchTeams
        settings.noMic = noMic
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
