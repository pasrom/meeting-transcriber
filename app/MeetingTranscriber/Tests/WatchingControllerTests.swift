@testable import MeetingTranscriber
import XCTest

/// Unit tests for `WatchingController` exercised on a bare controller (no full
/// `AppState`), focusing on the genuinely-new injection seams the extraction
/// enables: `ensureMicAccess` and `makeDetector`. Before the split,
/// `toggleWatching` hard-wired `Permissions.ensureMicrophoneAccess()` +
/// `PowerAssertionDetector()`, so neither the mic-access gate nor the detector
/// wiring was reachable in a unit test without real TCC / IOKit.
@MainActor
final class WatchingControllerTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// Builds a `WatchingController` wired to real (but inert) sibling
    /// controllers and the supplied seams. The pipeline gets a queue on an
    /// isolated `logDir` so `rebuild()` touches no production path, and the
    /// default detector never matches a window so no recording starts.
    private func makeController(
        ensureMicAccess: @escaping () async -> Bool = { true },
        makeDetector: @escaping () -> any MeetingDetecting = { makeSilentDetector() },
    ) -> WatchingController {
        let settings = AppSettings()
        let notifier = RecordingNotifier()
        let pipeline = PipelineController(settings: settings, notifier: notifier)
        pipeline.queue = PipelineQueue(logDir: tmpDir)
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
            makeDetector: makeDetector,
        )
    }

    // MARK: - ensureMicAccess seam

    func testToggleWatchingAwaitsInjectedMicAccess() async {
        var micAccessCalled = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`makeDetector`), not `ensureMicAccess`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            micAccessCalled = true
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(micAccessCalled)

        XCTAssertTrue(micAccessCalled, "toggleWatching must await the injected mic-access gate")
    }

    func testStartManualRecordingAwaitsInjectedMicAccess() async {
        var micAccessCalled = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`makeDetector`), not `ensureMicAccess`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            micAccessCalled = true
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(micAccessCalled)

        XCTAssertTrue(micAccessCalled, "startManualRecording must await the injected mic-access gate")
    }

    // MARK: - makeDetector seam

    func testToggleWatchingUsesInjectedDetectorFactory() async {
        var detectorMade = false
        // Not trailing-closure: with `ensureMicAccess` defaulted before it, a
        // trailing closure binds to `ensureMicAccess` (→ `Bool`), not `makeDetector`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(makeDetector: {
            detectorMade = true
            return makeSilentDetector()
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(detectorMade)

        XCTAssertTrue(detectorMade, "toggleWatching must build its detector via the injected factory")
    }

    // MARK: - Toggle / stop lifecycle

    func testToggleWatchingCreatesLoopThenSecondToggleStops() async {
        let controller = makeController()
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.toggleWatching()
        await waitFor(controller.watchLoop?.isActive == true)
        XCTAssertEqual(controller.watchLoop?.isActive, true, "first toggle should start an active loop")

        controller.toggleWatching()
        XCTAssertNil(controller.watchLoop, "second toggle should stop and clear the loop")
    }

    func testToggleWatchingNoOpWhileManualRecording() async throws {
        let controller = makeController()
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        controller.toggleWatching() // must be a no-op while a manual recording is live

        XCTAssertNotNil(controller.watchLoop)
        XCTAssertEqual(controller.watchLoop?.isManualRecording, true)
    }

    func testStopManualRecordingClearsLoop() async throws {
        let controller = makeController()
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")

        controller.stopManualRecording()

        XCTAssertNil(controller.watchLoop)
    }
}
