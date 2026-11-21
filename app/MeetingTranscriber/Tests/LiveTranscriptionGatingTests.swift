@testable import MeetingTranscriber
import XCTest

/// Boolean-gate tests for the live-transcription wiring:
///   * `TranscriptionEngineSetting.supportsLiveTranscription` — which engines
///     should expose the live toggle (Parakeet + WhisperKit yes).
///   * `AppState.shouldShowLiveCaptions` — covers the no-watchLoop branches
///     of the AND-gate, plus the recording + overlay path via a driven
///     `WatchLoop` (`ManualRecordingTests.makeLoop` / `makeTestWatchLoop`).
@MainActor
final class LiveTranscriptionGatingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "LiveTranscriptionGatingTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = DefaultsSuite.open(testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        settings = nil
        DefaultsSuite.remove(testSuiteName)
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    /// Every test here turns live captions on, so `AppState.init` prewarms a
    /// live controller; the inert factory keeps that prewarm off CoreML.
    private func makeState() throws -> AppState {
        try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(),
            settings: settings,
            liveControllerFactory: inertLiveControllerFactory(),
        )
    }

    // MARK: - supportsLiveTranscription

    func testParakeetSupportsLive() {
        XCTAssertTrue(TranscriptionEngineSetting.parakeet.supportsLiveTranscription)
    }

    func testWhisperKitSupportsLive() {
        XCTAssertTrue(TranscriptionEngineSetting.whisperKit.supportsLiveTranscription)
    }

    // MARK: - shouldShowLiveCaptions (watchLoop nil branch)

    func testShouldShowFalseWhenToggleOff() throws {
        settings.transcriptionEngine = .parakeet
        settings.liveTranscriptionEnabled = false
        let state = try makeState()
        XCTAssertFalse(state.shouldShowLiveCaptions)
    }

    func testShouldShowFalseWhenToggleOnSupportedEngineButNoActiveWatchLoop() throws {
        settings.transcriptionEngine = .parakeet
        settings.liveTranscriptionEnabled = true
        let state = try makeState()
        // No watch loop has been started → recording state is unreachable
        XCTAssertNil(state.watching.watchLoop)
        XCTAssertFalse(state.shouldShowLiveCaptions)
    }

    func testShouldShowFalseForWhisperKitWhenNoActiveWatchLoop() throws {
        settings.transcriptionEngine = .whisperKit
        settings.liveTranscriptionEnabled = true
        let state = try makeState()
        XCTAssertNil(state.watching.watchLoop)
        XCTAssertFalse(state.shouldShowLiveCaptions)
    }

    // MARK: - echo cancellation setting

    func testLiveControllerReadsEchoCancellationSetting() throws {
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "en"
        settings.liveTranscriptionEnabled = true
        settings.echoCancellationEnabled = false
        var built: LiveTranscriptionController?
        let inert = inertLiveControllerFactory()
        let state = try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(),
            settings: settings,
        ) { engine, captions, language, verbose in
            let controller = inert(engine, captions, language, verbose)
            built = controller
            return controller
        }
        _ = state
        let controller = try XCTUnwrap(built, "live captions on must prewarm a controller")
        XCTAssertFalse(controller.echoCancellationEnabled())
        settings.echoCancellationEnabled = true
        XCTAssertTrue(controller.echoCancellationEnabled(), "live captions must follow AppSettings.echoCancellationEnabled")
    }

    /// The live transcript file follows `AppSettings.liveTranscriptFileEnabled`, read per call.
    func testLiveControllerReadsTranscriptFileSetting() throws {
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "en"
        settings.liveTranscriptionEnabled = true
        settings.liveTranscriptFileEnabled = false
        let directory = makeTempFile(suffix: "-gating-transcripts")
        var built: LiveTranscriptionController?
        let inert = inertLiveControllerFactory()
        let state = try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(),
            settings: settings,
            liveTranscriptDirectory: directory,
        ) { engine, captions, language, verbose in
            let controller = inert(engine, captions, language, verbose)
            built = controller
            return controller
        }
        _ = state
        let factory = try XCTUnwrap(built?.transcriptFileFactory, "live captions on must prewarm a controller")
        XCTAssertNil(factory(), "off opens no file")
        settings.liveTranscriptFileEnabled = true
        let file = try XCTUnwrap(factory(), "live captions must follow AppSettings.liveTranscriptFileEnabled")
        XCTAssertEqual(
            file.url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL,
            "AppState hands its folder to the coordinator",
        )
    }

    /// The last synchronous step before exit writes `end` to a live transcript the
    /// quit's budget did not let finish.
    func testTearDownBeforeExitEndsALiveTranscriptStillWaiting() throws {
        let state = try AppState(pipelineEnvironment: makeIsolatedPipelineEnvironment(), settings: settings)
        let file = try XCTUnwrap(LiveTranscriptFile.open(in: makeTempFile(suffix: "-teardown")))
        file.eventsInFlight.enter() // a match that never returns
        state.liveTranscription.transcriptEnds.end(file, waitingUpTo: .seconds(30))

        state.tearDownBeforeExit()

        XCTAssertTrue(try String(contentsOf: file.url, encoding: .utf8).contains(#""type":"end""#))
    }

    // MARK: - shouldShowLiveCaptions (recording + overlay)

    /// Pins `AppState.shouldShowLiveCaptions` reading `settings.liveCaptionsOverlayEnabled`
    /// through a driven watch loop. Hardcoding `overlayEnabled: true` in
    /// `shouldShowLiveCaptions` must turn the overlay-off assertion red.
    func testShouldShowFollowsOverlayToggleWhileRecording() async throws {
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "en"
        settings.liveTranscriptionEnabled = true
        settings.liveCaptionsOverlayEnabled = true
        let state = try makeState()
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertEqual(loop.state, .recording)
        XCTAssertTrue(
            state.shouldShowLiveCaptions,
            "overlay on + recording + live on → captions bar should show",
        )

        settings.liveCaptionsOverlayEnabled = false
        XCTAssertFalse(
            state.shouldShowLiveCaptions,
            "overlay off must hide the captions bar while transcription still runs",
        )

        settings.liveCaptionsOverlayEnabled = true
        XCTAssertTrue(
            state.shouldShowLiveCaptions,
            "turning the overlay back on must show the captions bar again",
        )
    }
}

/// A live-caption controller factory whose controllers load no model, for an
/// `AppState` built with live captions on. `AppState.init` prewarms the
/// controller in a task nothing awaits; with the real factory that task compiles
/// the speaker-matcher, Parakeet, EOU and Nemotron CoreML models after the test
/// has returned, and those compiles have segfaulted inside CoreML while a later
/// class ran in the same xctest process. Here the speaker matcher and EOU
/// manager are fakes, the Nemotron load fails at once and there is no engine,
/// so `prepare()` resolves to no captions without touching CoreML.
private func inertLiveControllerFactory() -> LiveTranscriptionCoordinator.ControllerFactory {
    struct NoNemotronInTests: Error {}
    return { _, captions, engineLanguage, verboseDiagnostics in
        LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: engineLanguage,
            eouSessionFactory: { MockEouManager() },
            nemotronPipelineFactory: { _, _, _ in throw NoNemotronInTests() },
            verboseDiagnostics: verboseDiagnostics,
        )
    }
}
