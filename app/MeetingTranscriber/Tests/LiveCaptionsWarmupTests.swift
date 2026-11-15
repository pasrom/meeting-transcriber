import AudioTapLib
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

    /// A streaming session runs on its own models; the engine's state does not count.
    func testWarmupIsReadyOnAStreamingSessionWhileTheEngineIsUnloaded() async {
        let engine = WarmupTestEngine()
        let coordinator = makeCoordinator(engineLanguage: "en")

        coordinator.beginPrewarm { engine }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(engine.modelState, .unloaded, "test premise")
        XCTAssertEqual(coordinator.warmup, .ready)
    }

    func testWarmupIsReadyWhenAFailedStreamingLoadFallsBackToTheEngine() async {
        let coordinator = makeCoordinator(engineLanguage: "en", streamingLoadError: URLError(.notConnectedToInternet))

        coordinator.beginPrewarm { WarmupTestEngine() }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .ready)
    }

    /// The engine load does not throw, so only its state says no model is there.
    func testWarmupFailsWhenTheEngineLoadLeavesNoModel() async {
        let coordinator = makeCoordinator()

        coordinator.beginPrewarm { WarmupTestEngine(loads: false) }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .failed(LiveTranscriptionController.engineLoadFailure))
    }

    func testWarmupFailsWithTheStreamingErrorWhenTheFallbackEngineDoesNotLoadEither() async {
        let error = URLError(.notConnectedToInternet)
        let coordinator = makeCoordinator(engineLanguage: "en", streamingLoadError: error)

        coordinator.beginPrewarm { WarmupTestEngine(loads: false) }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .failed(error.localizedDescription))
    }

    /// A recording that started first built the re-transcribe pipelines, so
    /// `prepare()` must still run the load it judges.
    func testWarmupLoadsTheEngineWhenARecordingBuiltThePipelinesFirst() async {
        let engine = WarmupTestEngine()
        let controller = makeController(engine: engine)
        await controller.prepareForNextRecording()
        XCTAssertTrue(controller.usesTranscriptionEngine, "test premise: the pipelines exist")

        await controller.prepare()

        XCTAssertEqual(engine.loadCount, 1)
        XCTAssertNil(controller.prepareFailure)
    }

    func testLanguageDetectionWarmupFailsOnlyWhenTheEngineLoadLeavesNoModel() async {
        for loads in [false, true] {
            let engine = WarmupTestEngine(loads: loads)
            engine.detectsLanguage = true
            let controller = makeController(engine: engine)

            await controller.prepare()

            XCTAssertEqual(engine.loadCount, 1)
            XCTAssertEqual(controller.prepareFailure, loads ? nil : LiveTranscriptionController.engineLoadFailure)
        }
    }

    func testWarmupFailsWhenTheLoadAfterARecordingBuiltThePipelinesLeavesNoModel() async {
        let engine = WarmupTestEngine(loads: false)
        let controller = makeController(engine: engine)
        await controller.prepareForNextRecording()

        await controller.prepare()

        XCTAssertEqual(engine.loadCount, 1)
        XCTAssertEqual(controller.prepareFailure, LiveTranscriptionController.engineLoadFailure)
    }

    func testWarmupKeepsALoadedEngineWhenARecordingBuiltThePipelinesFirst() async {
        let engine = WarmupTestEngine()
        engine.modelState = .loaded
        let controller = makeController(engine: engine)
        await controller.prepareForNextRecording()

        await controller.prepare()

        XCTAssertEqual(engine.loadCount, 0, "a load would rebuild the loaded model")
        XCTAssertNil(controller.prepareFailure)
    }

    /// A repeated `prepare()` on a streaming session finds pipelines too; they do not run on the engine.
    func testARepeatedPrepareOnAStreamingSessionDoesNotLoadTheEngine() async {
        let engine = WarmupTestEngine()
        let controller = makeController(engine: engine, engineLanguage: "en")
        await controller.prepare()
        XCTAssertFalse(controller.usesTranscriptionEngine, "test premise: the EOU sessions are built")

        await controller.prepare()

        XCTAssertEqual(engine.loadCount, 0)
    }

    func testAFailureReasonDoesNotCarryTheHomeDirectory() async {
        let error = ModelPathError(path: NSHomeDirectory() + "/Library/model.mlmodelc")
        let coordinator = makeCoordinator(engineSupportsLive: false, engineLanguage: "en", streamingLoadError: error)

        coordinator.beginPrewarm { WarmupTestNonStreamingEngine() }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .failed("Could not load ~/Library/model.mlmodelc"))
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
        XCTAssertEqual(coordinator.warmup, .idle, "the stale warm-up must not write its outcome")
    }

    /// A dropped controller's warm-up ends while its successor's is still running.
    func testAStaleWarmupFinishingLeavesItsSuccessorPreparing() async throws {
        let queue = ModelWarmupQueue()
        let blocker = MainActorGate()
        let blocked = Task { @MainActor in await queue.run { await blocker.wait() } }
        await waitFor(blocker.hasWaiter)
        let engine = WarmupTestEngine(gated: true)
        let (coordinator, settings) = try makeSettingsCoordinator(warmupQueue: queue)
        coordinator.beginPrewarm { engine }
        guard case let .preparing(first) = coordinator.warmup else {
            XCTFail("test premise: the first warm-up is queued")
            return
        }

        settings.parakeetLanguage = "bs" // untrained, so still re-transcribe
        await waitFor(coordinator.warmup.isPreparing && coordinator.warmup != .preparing(since: first))
        let successor = coordinator.warmup
        blocker.open()
        await blocked.value
        await waitFor(engine.gate.hasWaiter) // the successor's load; the stale warm-up ended before it

        XCTAssertEqual(engine.loadCount, 1, "test premise: only the successor loads")
        XCTAssertEqual(coordinator.warmup, successor)
        engine.gate.open()
        await queue.run {}
        XCTAssertEqual(coordinator.warmup, .ready)
    }

    /// A manual start builds its recorder before the state is recording; a
    /// settings change in that window must not drop the controller being attached.
    func testASettingsChangeDuringAnAttachWaitsForTheNextIdleFlush() async throws {
        let suiteName = "LiveCaptionsWarmupTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suiteName)))
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "en"
        settings.liveTranscriptionEnabled = true
        let finish = AsyncGate()
        var built = 0
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { settings.liveTranscriptionEnabled },
            engineSupportsLive: { settings.transcriptionEngine.supportsLiveTranscription },
            engineLanguage: { settings.activeEngineLanguageOrNil },
            verboseDiagnostics: { false },
            makeController: { engine, captions, engineLanguage, _ in
                built += 1
                return self.makeController(engine: engine, captions: captions, engineLanguage: engineLanguage) {
                    GatedEouManager(gate: AsyncGate(), finishGate: finish)
                }
            },
        )
        coordinator.beginPrewarm { WarmupTestEngine() }
        await waitFor(!coordinator.warmup.isPreparing, timeout: .seconds(5))
        XCTAssertEqual(coordinator.warmup, .ready, "test premise: the EOU sessions are built")

        // Hold the stop-time flush, so the next attach waits inside `attachSinks`.
        let first = DualSourceRecorder()
        await coordinator.attachSinks(to: first)
        first.micLiveSink?(LiveAudioBuffer(samples: [0, 0, 0, 0], channelCount: 1, sampleRate: 16000, hostTime: 0))
        let flush = Task { await coordinator.flush() }
        await waitFor { await finish.hasWaiter }
        let second = DualSourceRecorder()
        let attach = Task { await coordinator.attachSinks(to: second) }
        await waitFor(coordinator.attachInFlight)
        XCTAssertNil(second.micLiveSink, "test premise: the attach is still in flight")

        settings.parakeetLanguage = ""
        await waitFor(coordinator.needsRewarmWhenIdle || built > 1) // deferred, or dropped and rebuilt
        XCTAssertEqual(built, 1, "the controller being attached must be kept")

        await finish.open()
        await attach.value
        await flush.value
        XCTAssertNotNil(second.micLiveSink)
        await coordinator.flush()
        XCTAssertEqual(built, 2, "the change applies at the next idle flush")
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

    /// The same for the load `prepare()` runs when a recording built the pipelines first.
    func testCancelDuringTheLoadAfterARecordingBuiltThePipelinesPublishesNoBackend() async {
        let engine = WarmupTestEngine(gated: true)
        let captions = LiveCaptionsState()
        let controller = makeController(engine: engine, captions: captions)
        await controller.prepareForNextRecording()
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
    private let loads: Bool

    /// `loads: false` fails as the real engines do: no throw, back to `.unloaded`.
    init(gated: Bool = false, loads: Bool = true) {
        self.loads = loads
        if !gated { gate.open() }
    }

    func loadModel() async {
        loadCount += 1
        await gate.wait()
        if loads { modelState = .loaded }
    }

    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }

    func transcribeSamples(_: [Float]) -> String {
        ""
    }

    var detectsLanguage = false
    var supportsCaptionLanguageDetection: Bool {
        detectsLanguage
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
    private let finishGate: AsyncGate?

    /// With a `finishGate` the load is not held; `finish()` is.
    init(gate: AsyncGate, loadError: (any Error)? = nil, finishGate: AsyncGate? = nil) {
        self.gate = gate
        self.loadError = loadError
        self.finishGate = finishGate
    }

    func loadModels() async throws {
        if finishGate == nil { await gate.wait() }
        if let loadError { throw loadError }
    }

    func appendAudio(_: AVAudioPCMBuffer) {}
    func processBufferedAudio() {}
    func finish() async -> String {
        await finishGate?.wait()
        return ""
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

    func match(audio _: [Float]) -> LiveSpeakerMatch {
        .unknown
    }

    func probe(audio _: [Float]) -> LiveSpeakerMatch {
        .unknown
    }
}

private struct ModelPathError: LocalizedError {
    let path: String
    var errorDescription: String? {
        "Could not load \(path)"
    }
}
