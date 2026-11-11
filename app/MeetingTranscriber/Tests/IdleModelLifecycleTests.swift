import FluidAudio
@testable import MeetingTranscriber
import Observation
import WhisperKit
import XCTest

@MainActor
final class IdleModelLifecycleTests: XCTestCase {
    func testDrainDoesNotRequireAnObserverToHaveSeenTheQueueBusy() async throws {
        let app = try makeIsolatedAppState()
        try await installModel(on: app.engines.whisperKit)
        await app.engines.whisperKit.loadModel()
        app.pipeline.queue.vad = FluidVAD(threshold: 0.5)

        // No suspension or explicit settings sync between these transitions.
        app.pipeline.queue.isProcessing = true
        await app.pipeline.queue.processNext()
        await waitFor(app.engines.whisperKit.modelState == .unloaded)

        XCTAssertEqual(app.engines.whisperKit.modelState, .unloaded)
        XCTAssertNil(app.pipeline.queue.vad)
    }

    func testReplacingADrainedQueueDoesNotLoseItsRelease() async throws {
        let app = try makeIsolatedAppState()
        let oldQueue = app.pipeline.queue
        try await installModel(on: app.engines.whisperKit)
        await app.engines.whisperKit.loadModel()
        oldQueue.vad = FluidVAD(threshold: 0.5)
        let replacement = try makeIsolatedQueue()

        oldQueue.isProcessing = true
        await oldQueue.processNext()
        app.pipeline.installQueueForTesting(replacement)
        await waitFor(app.engines.whisperKit.modelState == .unloaded)

        XCTAssertEqual(app.engines.whisperKit.modelState, .unloaded)
        XCTAssertNil(oldQueue.vad)
    }

    func testQueueDrainReleasesASRAndBatchVADButBackToBackJobsKeepThem() async throws {
        let app = try makeIsolatedAppState()
        let queue = app.pipeline.queue
        try await installModel(on: app.engines.whisperKit)
        await app.engines.whisperKit.loadModel()
        queue.vad = FluidVAD(threshold: 0.5)
        queue.isProcessing = true
        app.engines.syncEngineSettings()
        queue.insertJobForTesting(PipelineJob(
            meetingTitle: "Next job", appName: "File", mixPath: nil,
            appPath: nil, micPath: nil, micDelay: 0,
        ))
        queue.isProcessing = false
        app.engines.syncEngineSettings()
        XCTAssertEqual(app.engines.whisperKit.modelState, .loaded)
        XCTAssertNotNil(queue.vad)

        queue.jobs = []
        queue.isProcessing = true
        app.engines.syncEngineSettings()
        await queue.processNext()
        await waitFor(app.engines.whisperKit.modelState == .unloaded)

        XCTAssertEqual(app.engines.whisperKit.modelState, .unloaded)
        XCTAssertNil(queue.vad)
    }

    func testCaptionsUsingASRKeepItAtDrainButReleaseBatchVAD() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        let captions = IdleModelCaptionState()
        captions.usesEngine = true
        engines.activateModelLifetime(queue: { queue }, isRecording: { false }, captionsUseEngine: { captions.usesEngine })
        try await installModel(on: engines.whisperKit)
        await engines.whisperKit.loadModel()
        queue.vad = FluidVAD(threshold: 0.5)
        queue.isProcessing = true
        engines.syncEngineSettings()
        await queue.processNext()
        engines.syncEngineSettings()

        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
        XCTAssertNil(queue.vad)

        captions.usesEngine = false
        await waitFor(engines.whisperKit.modelState == .unloaded)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    /// A failed EOU load falls back to re-transcribing on the shared engine.
    func testCaptionsFallingBackToTheEngineKeepItAtDrain() async throws {
        struct EouUnavailable: Error {}
        let settings = try makeIsolatedSettings()
        settings.liveTranscriptionEnabled = true
        settings.whisperLanguage = "en"
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { MockEouManager(loadError: EouUnavailable()) }
        let factory: LiveTranscriptionCoordinator.ControllerFactory = { engine, captions, language, verbose in
            LiveTranscriptionController(
                engine: engine,
                vad: FluidVAD(threshold: 0.5),
                captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(),
                engineLanguage: language,
                eouSessionFactory: eouFactory,
                verboseDiagnostics: verbose,
            )
        }
        // Built first: the source must be in place before prepare() can run.
        let source = try await makeModelSource()
        let app = try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(),
            settings: settings,
            liveControllerFactory: factory,
        )
        app.engines.whisperKit.installModelSourceForTesting(source)
        // The flag is set before the fallback's load, so wait for the load itself.
        await waitFor(app.engines.whisperKit.modelState == .loaded, timeout: .seconds(5))
        XCTAssertTrue(app.liveTranscription.captionsUseEngine, "test premise: the fallback runs on the engine")

        app.pipeline.queue.isProcessing = true
        app.engines.syncEngineSettings()
        await app.pipeline.queue.processNext()
        app.engines.syncEngineSettings()

        XCTAssertEqual(app.engines.whisperKit.modelState, .loaded)
    }

    func testOffKeepsModelsAtDrainAndAnIdleFlipOnReleasesImmediately() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        await engines.preloadActiveModel()
        queue.vad = FluidVAD(threshold: 0.5)
        queue.isProcessing = true
        engines.syncEngineSettings()
        await queue.processNext()
        engines.syncEngineSettings()
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
        XCTAssertNotNil(queue.vad)

        settings.unloadModelsWhenIdle = true
        await waitFor(engines.whisperKit.modelState == .unloaded)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
        XCTAssertNil(queue.vad)
    }

    func testIdleFlipOffLoadsImmediately() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        try await installModel(on: engines.whisperKit)

        settings.unloadModelsWhenIdle = false
        await waitFor(engines.whisperKit.modelState == .loaded)

        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
    }

    func testPreloadSkipsAnAlreadyLoadedModel() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        let engines = EngineController(settings: settings)
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        let builds = PipeBuildCounter()
        engines.whisperKit.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in URL(fileURLWithPath: "/unused-model") },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in
                await builds.increment()
                return pipe
            },
        ))
        await engines.preloadActiveModel()
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)

        // Turning idle unloading off while the model is loaded preloads again.
        await engines.preloadActiveModel(whenIdle: true)

        let count = await builds.count
        XCTAssertEqual(count, 1, "a loaded model must not be rebuilt")
    }

    func testAppStateKeepsASRUntilTheStopTimeCaptionFlushCompletes() async throws {
        let app = try makeIsolatedAppState()
        app.settings.unloadModelsWhenIdle = false
        app.engines.syncEngineSettings()
        try await installModel(on: app.engines.whisperKit)
        await app.engines.preloadActiveModel()

        app.watching.flushLiveTranscriptionAfterRecording()
        app.settings.unloadModelsWhenIdle = true
        app.engines.syncEngineSettings()
        XCTAssertEqual(app.engines.whisperKit.modelState, .loaded)
        XCTAssertEqual(app.watching.captionFlushesInFlight, 1)

        await waitFor(app.engines.whisperKit.modelState == .unloaded)
        XCTAssertEqual(app.engines.whisperKit.modelState, .unloaded)
        XCTAssertEqual(app.watching.captionFlushesInFlight, 0)
    }

    func testMidJobFlipOnDefersReleaseToDrain() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        await engines.preloadActiveModel()
        queue.isProcessing = true
        settings.unloadModelsWhenIdle = true
        engines.syncEngineSettings()
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)

        await queue.processNext()
        await waitFor(engines.whisperKit.modelState == .unloaded)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testMidJobFlipOffDefersLoadToDrain() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        queue.isProcessing = true
        settings.unloadModelsWhenIdle = false
        engines.syncEngineSettings()
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)

        await queue.processNext()
        await waitFor(engines.whisperKit.modelState == .loaded)
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
    }

    func testRecordingDefersTheInactiveEngineRelease() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let recording = IdleModelRecordingState()
        engines.activateModelLifetime(queue: { nil }, isRecording: { recording.active })
        try await installModel(on: engines.whisperKit)
        await engines.whisperKit.loadModel()
        recording.active = true
        engines.syncEngineSettings()
        settings.transcriptionEngine = .parakeet
        engines.syncEngineSettings()
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)

        recording.active = false
        await waitFor(engines.whisperKit.modelState == .unloaded)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    /// Off keeps it: the queue still runs on the engine it was built with.
    func testIdleEngineSwitchReleasesTheInactiveModelOnlyWithIdleUnloading() async throws {
        for enabled in [false, true] {
            let settings = try makeIsolatedSettings()
            settings.unloadModelsWhenIdle = enabled
            let engines = EngineController(settings: settings)
            try await installModel(on: engines.whisperKit)
            await engines.whisperKit.loadModel()
            settings.transcriptionEngine = .parakeet
            engines.syncEngineSettings()
            XCTAssertEqual(engines.whisperKit.modelState, enabled ? .unloaded : .loaded, "enabled: \(enabled)")

            engines.parakeetEngine.installModelManagerForTesting { AsrManager(config: .default) }
            await engines.parakeetEngine.loadModel()
            settings.transcriptionEngine = .whisperKit
            engines.syncEngineSettings()
            XCTAssertEqual(engines.parakeetEngine.modelState, enabled ? .unloaded : .loaded, "enabled: \(enabled)")
        }
    }

    func testExplicitLoadStaysUntilTheNextDrain() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        await engines.whisperKit.loadModel()
        settings.whisperLanguage = "id"
        engines.syncEngineSettings()
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)

        queue.isProcessing = true
        engines.syncEngineSettings()
        await queue.processNext()
        await waitFor(engines.whisperKit.modelState == .unloaded)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testStaleWarmupCannotKeepAnInactiveEngineResident() async throws {
        let settings = try makeIsolatedSettings()
        settings.parakeetLanguage = "id"
        let engines = EngineController(settings: settings)
        try await installModel(on: engines.whisperKit)
        settings.transcriptionEngine = .parakeet
        await waitFor(engines.parakeetEngine.language == "id")
        XCTAssertEqual(engines.parakeetEngine.language, "id")

        // A caption warm-up already queued before the switch can call the old
        // engine after its initial release. It must not leave that engine warm.
        await engines.whisperKit.loadModel()
        await waitFor(engines.whisperKit.modelState == .unloaded)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testIdleUnloadingDefaultsOnAndSkipsLaunchPreload() async throws {
        let settings = try makeIsolatedSettings()
        XCTAssertTrue(settings.unloadModelsWhenIdle)
        let engines = EngineController(settings: settings)
        try await installModel(on: engines.whisperKit)

        await engines.preloadActiveModel()

        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testDisablingIdleUnloadingPreservesLaunchPreload() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        let engines = EngineController(settings: settings)
        try await installModel(on: engines.whisperKit)

        await engines.preloadActiveModel()

        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
    }

    func testOffLaunchPreloadStillRunsWithQueuedWork() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        queue.isProcessing = true
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)

        await engines.preloadActiveModel()

        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
    }

    // MARK: - Drain after a job ran

    func testACompletedJobsDrainReleasesTheModelAndBatchVAD() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let dir = try makeTempDirectory(prefix: "idle_model_done")
        let jobEngine = MockEngine()
        jobEngine.segmentsToReturn = [TimestampedSegment(start: 0, end: 1, text: "Words")]
        let queue = makeJobQueue(engine: jobEngine, dir: dir)
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        await engines.whisperKit.loadModel()
        queue.vad = FluidVAD(threshold: 0.5)

        try queue.enqueue(PipelineJob(
            meetingTitle: "Call", appName: "Teams",
            mixPath: createTestAudioFile(in: dir), appPath: nil, micPath: nil, micDelay: 0,
        ))
        await queue.awaitProcessing()
        await waitFor(engines.whisperKit.modelState == .unloaded)

        XCTAssertEqual(queue.jobs.first?.state, .done, "test premise: the job ran to completion")
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
        XCTAssertNil(queue.vad)
    }

    /// Settings must still show why the load failed after the drain releases it.
    func testAFailedJobsDrainKeepsTheLoadFailureReason() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let dir = try makeTempDirectory(prefix: "idle_model_error")
        engines.whisperKit.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))
        let queue = makeJobQueue(engine: engines.whisperKit, dir: dir)
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        let generation = engines.whisperKit.modelGeneration

        try queue.enqueue(PipelineJob(
            meetingTitle: "Call", appName: "Teams",
            mixPath: createTestAudioFile(in: dir), appPath: nil, micPath: nil, micDelay: 0,
        ))
        await queue.awaitProcessing()
        await waitFor(engines.whisperKit.modelGeneration > generation)

        XCTAssertEqual(queue.jobs.first?.state, .error, "test premise: the job failed")
        XCTAssertGreaterThan(engines.whisperKit.modelGeneration, generation, "test premise: the drain released the engine")
        XCTAssertNotNil(engines.whisperKit.loadFailureReason)
    }

    private func makeJobQueue(engine: any TranscribingEngine, dir: URL) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir,
            logDir: dir,
            micLabel: "Me",
        )
    }

    private func installModel(on engine: WhisperKitEngine) async throws {
        try await engine.installModelSourceForTesting(makeModelSource())
    }

    private func makeModelSource() async throws -> WhisperKitModelSource {
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        return WhisperKitModelSource(
            locateLocal: { _ in URL(fileURLWithPath: "/unused-model") },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in pipe },
        )
    }
}

private actor PipeBuildCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

@MainActor
@Observable
private final class IdleModelRecordingState {
    var active = false
}

@MainActor
@Observable
private final class IdleModelCaptionState {
    var usesEngine = false
}
