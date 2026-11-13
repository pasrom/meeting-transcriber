import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// The warm-up state `LiveTranscriptionCoordinator` reports, and the cancel that
/// stops a dropped controller's `prepare()` between its model loads.
@MainActor
final class LiveCaptionsWarmupTests: XCTestCase {
    /// A controller whose `prepare()` loads no real model.
    private func controllerFactory(
        streamingLoadError: (any Error)? = nil,
    ) -> LiveTranscriptionCoordinator.ControllerFactory {
        { engine, captions, engineLanguage, verboseDiagnostics in
            let eouFactory: LiveTranscriptionController.EouSessionFactory = { MockEouManager(loadError: streamingLoadError) }
            return LiveTranscriptionController(
                engine: engine,
                vad: FluidVAD(threshold: 0.5),
                captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(),
                engineLanguage: engineLanguage,
                eouSessionFactory: eouFactory,
                nemotronPipelineFactory: { _, _, _ in throw streamingLoadError ?? URLError(.unknown) },
                verboseDiagnostics: verboseDiagnostics,
            )
        }
    }

    /// A controller driven directly, for the cancel points inside `prepare()`.
    private func makeController(
        engine: (any StreamingTranscribingEngine)? = nil,
        captions: LiveCaptionsState = LiveCaptionsState(),
        speakerMatcher: any LiveSpeakerMatching = FakeLiveSpeakerMatcher(),
        engineLanguage: String? = nil,
        eouSessionFactory: @escaping LiveTranscriptionController.EouSessionFactory = { MockEouManager() },
    ) -> LiveTranscriptionController {
        LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: speakerMatcher,
            engineLanguage: engineLanguage,
            eouSessionFactory: eouSessionFactory,
        )
    }

    private func makeCoordinator(
        engineSupportsLive: Bool = true,
        engineLanguage: String? = nil,
        streamingLoadError: (any Error)? = nil,
        warmupQueue: ModelWarmupQueue = ModelWarmupQueue(),
    ) -> LiveTranscriptionCoordinator {
        LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { engineSupportsLive },
            engineLanguage: { engineLanguage },
            verboseDiagnostics: { false },
            makeController: controllerFactory(streamingLoadError: streamingLoadError),
            warmupQueue: warmupQueue,
        )
    }

    /// Captions on over real settings, so a settings write reaches the coordinator's observer.
    private func makeSettingsCoordinator(
        warmupQueue: ModelWarmupQueue,
    ) throws -> (LiveTranscriptionCoordinator, AppSettings) {
        let suiteName = "LiveCaptionsWarmupTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suiteName)))
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = ""
        settings.liveTranscriptionEnabled = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { settings.liveTranscriptionEnabled },
            engineSupportsLive: { settings.transcriptionEngine.supportsLiveTranscription },
            engineLanguage: { settings.activeEngineLanguageOrNil },
            verboseDiagnostics: { false },
            makeController: controllerFactory(),
            warmupQueue: warmupQueue,
        )
        return (coordinator, settings)
    }

    // MARK: - State

    func testWarmupIsPreparingUntilPrepareFinishesThenReady() async {
        let queue = ModelWarmupQueue()
        let engine = WarmupTestEngine(gated: true)
        let coordinator = makeCoordinator(warmupQueue: queue)
        XCTAssertEqual(coordinator.warmup, .idle)

        coordinator.beginPrewarm { engine }
        let before = Date()
        await waitFor(engine.gate.hasWaiter)
        guard case let .preparing(since) = coordinator.warmup else {
            XCTFail("expected preparing, got \(coordinator.warmup)")
            return
        }
        XCTAssertLessThan(abs(since.timeIntervalSince(before)), 5, "counts from when the warm-up began")

        engine.gate.open()
        await queue.run {}
        XCTAssertEqual(coordinator.warmup, .ready)
    }

    /// No streaming engine to fall back to, so the failed load leaves no captions.
    func testWarmupFailsWithTheLoadErrorWhenNoBackendLoaded() async {
        let error = URLError(.notConnectedToInternet)
        let coordinator = makeCoordinator(engineSupportsLive: false, engineLanguage: "en", streamingLoadError: error)

        coordinator.beginPrewarm { WarmupTestNonStreamingEngine() }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .failed(error.localizedDescription))
    }

    func testWarmupFailsWithTheNemotronLoadError() async {
        let error = URLError(.timedOut)
        let coordinator = makeCoordinator(engineSupportsLive: false, engineLanguage: "de", streamingLoadError: error)

        coordinator.beginPrewarm { WarmupTestNonStreamingEngine() }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .failed(error.localizedDescription))
    }

    func testWarmupIsReadyWhenAFailedStreamingLoadFallsBackToTheEngine() async {
        let coordinator = makeCoordinator(engineLanguage: "en", streamingLoadError: URLError(.notConnectedToInternet))

        coordinator.beginPrewarm { WarmupTestEngine() }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .ready)
    }

    func testDisablingCaptionsClearsTheWarmupState() async throws {
        let (coordinator, settings) = try makeSettingsCoordinator(warmupQueue: ModelWarmupQueue())
        coordinator.beginPrewarm { WarmupTestEngine() }
        XCTAssertTrue(coordinator.warmup.isPreparing, "test premise")

        settings.liveTranscriptionEnabled = false
        await waitFor(coordinator.warmup == .idle)

        XCTAssertEqual(coordinator.warmup, .idle)
    }

    // MARK: - Cancelling a stale warm-up

    /// A warm-up still waiting in the queue when its controller is dropped must
    /// not go on to load its models.
    func testASettingsChangeCancelsTheStaleWarmup() async throws {
        let queue = ModelWarmupQueue()
        let blocker = MainActorGate()
        let blocked = Task { @MainActor in await queue.run { await blocker.wait() } }
        await waitFor(blocker.hasWaiter)
        let engine = WarmupTestEngine()
        let (coordinator, settings) = try makeSettingsCoordinator(warmupQueue: queue)
        coordinator.beginPrewarm { engine }
        XCTAssertTrue(coordinator.warmup.isPreparing, "test premise: a warm-up is queued")

        settings.liveTranscriptionEnabled = false
        await waitFor(coordinator.warmup == .idle)
        blocker.open()
        await blocked.value
        await queue.run {} // after the stale prepare()

        XCTAssertEqual(engine.loadCount, 0)
    }

    func testCancelDuringTheFirstChannelLoadSkipsTheSecondChannel() async {
        let gate = AsyncGate()
        var managersBuilt = 0
        let eouFactory: LiveTranscriptionController.EouSessionFactory = {
            managersBuilt += 1
            return GatedEouManager(gate: gate)
        }
        let controller = makeController(engineLanguage: "en", eouSessionFactory: eouFactory)
        let prepare = Task { await controller.prepare() }
        await waitFor { await gate.hasWaiter }

        controller.cancelPrepare()
        await gate.open()
        await prepare.value

        XCTAssertEqual(managersBuilt, 1, "the app channel must not load after the cancel")
    }

    func testCancelBeforePrepareStartsSkipsTheSpeakerMatcher() async {
        let matcher = GatedSpeakerMatcher(gate: AsyncGate())
        await matcher.gate.open()
        let controller = makeController(speakerMatcher: matcher)

        controller.cancelPrepare()
        await controller.prepare()

        let prepared = await matcher.prepareCount
        XCTAssertEqual(prepared, 0)
    }

    func testCancelDuringTheSpeakerMatcherLoadSkipsTheCaptionModels() async {
        let matcher = GatedSpeakerMatcher(gate: AsyncGate())
        var managersBuilt = 0
        let eouFactory: LiveTranscriptionController.EouSessionFactory = {
            managersBuilt += 1
            return MockEouManager()
        }
        let controller = makeController(speakerMatcher: matcher, engineLanguage: "en", eouSessionFactory: eouFactory)
        let prepare = Task { await controller.prepare() }
        await waitFor { await matcher.gate.hasWaiter }

        controller.cancelPrepare()
        await matcher.gate.open()
        await prepare.value

        XCTAssertEqual(managersBuilt, 0)
    }

    /// The streaming load fails after the cancel; its fallback must not load the engine.
    func testCancelDuringAFailingStreamingLoadSkipsTheEngineFallback() async {
        let gate = AsyncGate()
        let engine = WarmupTestEngine()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = {
            GatedEouManager(gate: gate, loadError: URLError(.notConnectedToInternet))
        }
        let controller = makeController(engine: engine, engineLanguage: "en", eouSessionFactory: eouFactory)
        let prepare = Task { await controller.prepare() }
        await waitFor { await gate.hasWaiter }

        controller.cancelPrepare()
        await gate.open()
        await prepare.value

        XCTAssertEqual(engine.loadCount, 0)
    }

    /// The engine load is not interrupted, but its controller must not publish
    /// a backend over its successor's.
    func testCancelDuringTheEngineLoadPublishesNoBackend() async {
        let engine = WarmupTestEngine(gated: true)
        let captions = LiveCaptionsState()
        let controller = makeController(engine: engine, captions: captions)
        let prepare = Task { await controller.prepare() }
        await waitFor(engine.gate.hasWaiter)

        controller.cancelPrepare()
        engine.gate.open()
        await prepare.value

        XCTAssertNil(captions.activeBackend)
    }
}

/// A streaming engine that counts its model loads and can hold one for the test.
@MainActor
private final class WarmupTestEngine: StreamingTranscribingEngine {
    let gate = MainActorGate()
    var modelState: EngineModelState = .unloaded
    var downloadProgress: Double = 0
    var transcriptionProgress: Double = 0
    private(set) var loadCount = 0

    init(gated: Bool = false) {
        if !gated { gate.open() }
    }

    func loadModel() async {
        loadCount += 1
        await gate.wait()
    }

    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }

    func transcribeSamples(_: [Float]) -> String {
        ""
    }
}

@MainActor
private final class WarmupTestNonStreamingEngine: TranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1.0
    var transcriptionProgress: Double = 1.0
    func loadModel() {}
    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }
}

/// An EOU manager whose model load waits for the test.
private actor GatedEouManager: EouStreamingAsrManaging {
    private let gate: AsyncGate
    private let loadError: (any Error)?

    init(gate: AsyncGate, loadError: (any Error)? = nil) {
        self.gate = gate
        self.loadError = loadError
    }

    func loadModels() async throws {
        await gate.wait()
        if let loadError { throw loadError }
    }

    func appendAudio(_: AVAudioPCMBuffer) {}
    func processBufferedAudio() {}
    func finish() -> String {
        ""
    }

    func reset() {}
    func setPartialCallback(_: @Sendable (String) -> Void) {}
    func setEouCallback(_: @Sendable (String) -> Void) {}
    func getEouTimestampsMs() -> [Int] {
        []
    }
}

/// A speaker matcher that counts its model loads and holds each for the test.
private actor GatedSpeakerMatcher: LiveSpeakerMatching {
    let gate: AsyncGate
    private(set) var prepareCount = 0

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func prepare() async {
        prepareCount += 1
        await gate.wait()
    }

    func match(audio _: [Float]) -> String? {
        nil
    }
}
