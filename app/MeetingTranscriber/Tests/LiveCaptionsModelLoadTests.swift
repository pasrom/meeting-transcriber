@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// The streaming caption models across rebuilt controllers: a first download runs
/// before the warm-up queue, so its stall deadline does not count it; a rebuilt
/// controller waits for a download of the same models in flight instead of running
/// a second one beside it, but does not wait for their load.
@MainActor
final class LiveCaptionsModelLoadTests: XCTestCase {
    private typealias StreamingModel = LiveTranscriptionController.StreamingModel

    /// Nemotron for German, Parakeet EOU for English.
    private let languages: [(language: String, model: StreamingModel)] = [
        ("de", .nemotron(languageCode: "de")),
        ("en", .eou),
    ]

    private var stalledFailure: String {
        LiveTranscriptionCoordinator.stalledFailure(after: ModelWarmupQueue.defaultStallDeadline)
    }

    /// Captions on over real settings with the engine language `language`, every
    /// controller's model downloads and loads going through `models`.
    private func makeCoordinator(
        language: String,
        models: FakeCaptionModels,
        queue: ModelWarmupQueue,
    ) throws -> (LiveTranscriptionCoordinator, AppSettings) {
        let suiteName = "LiveCaptionsModelLoadTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suiteName)))
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = language
        settings.liveTranscriptionEnabled = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { settings.liveTranscriptionEnabled },
            engineSupportsLive: { settings.transcriptionEngine.supportsLiveTranscription },
            engineLanguage: { settings.activeEngineLanguageOrNil },
            verboseDiagnostics: { false },
            makeController: { engine, captions, language, verbose in
                let controller = LiveTranscriptionController(
                    engine: engine,
                    vad: FluidVAD(threshold: 0.5),
                    captions: captions,
                    speakerMatcher: FakeLiveSpeakerMatcher(),
                    engineLanguage: language,
                    eouSessionFactory: { CountingEouManager(models: models) },
                    nemotronPipelineFactory: { _, _, _ in
                        await models.load()
                        return (RecordingCaptionPipeline(blockFirst: false), RecordingCaptionPipeline(blockFirst: false))
                    },
                    verboseDiagnostics: verbose,
                )
                controller.streamingModelDownload = { try await models.download($0) }
                return controller
            },
            warmupQueue: queue,
        )
        return (coordinator, settings)
    }

    /// Turning captions off and on while idle drops the controller and builds a new one.
    private func rebuild(_ coordinator: LiveTranscriptionCoordinator, _ settings: AppSettings) async {
        settings.liveTranscriptionEnabled = false
        await waitFor(coordinator.warmup == .idle)
        settings.liveTranscriptionEnabled = true
        await waitFor(coordinator.warmup.isPreparing)
    }

    func testAFirstDownloadRunsBeforeTheWarmupQueueAndItsStallDeadline() async throws {
        for (language, model) in languages {
            let models = FakeCaptionModels()
            let download = models.holdDownload(0)
            let deadline = ManualDeadline()
            let (coordinator, _) = try makeCoordinator(language: language, models: models, queue: ModelWarmupQueue(sleep: deadline.sleep))
            coordinator.beginPrewarm { WarmupTestEngine() }
            await waitFor(download.hasWaiter)
            // Bounded: a deadline armed with the download would be waiting within it.
            await waitFor(deadline.waiting == 1, timeout: .milliseconds(50))

            XCTAssertEqual(models.downloads, [model], language)
            XCTAssertEqual(deadline.waiting, 0, "\(language): a download in flight must not be counted against the stall deadline")
            XCTAssertEqual(models.loads, 0, "\(language): the load comes after the download")
            XCTAssertTrue(coordinator.warmup.isPreparing, language)
            download.open()
            await waitFor(coordinator.warmup == .ready)
            XCTAssertEqual(coordinator.warmup, .ready, language)
            XCTAssertGreaterThan(models.loads, 0, language)
            deadline.pass()
        }
    }

    func testARebuiltControllerWaitsForTheDownloadInFlight() async throws {
        for (language, model) in languages {
            let models = FakeCaptionModels()
            let download = models.holdDownload(0)
            let (coordinator, settings) = try makeCoordinator(language: language, models: models, queue: ModelWarmupQueue())
            coordinator.beginPrewarm { WarmupTestEngine() }
            await waitFor(download.hasWaiter)

            await rebuild(coordinator, settings)
            // Bounded: with the fix the successor never gets there while the first runs.
            await waitFor(models.downloads.count == 2, timeout: .milliseconds(50))
            XCTAssertEqual(models.downloads, [model], "\(language): the successor must not download beside the one in flight")
            download.open()
            await waitFor(coordinator.warmup == .ready)

            XCTAssertEqual(coordinator.warmup, .ready, language)
            XCTAssertEqual(models.mostDownloadsAtOnce, 1, language)
            XCTAssertEqual(models.downloads, [model, model], "\(language): the successor checks the files once the first returned")
        }
    }

    /// Downloads into another folder do not wait: Swedish uses the multilingual
    /// Nemotron variant, German the Latin one.
    func testADownloadOfAnotherNemotronVariantDoesNotWait() async throws {
        let models = FakeCaptionModels()
        let latin = models.holdDownload(0)
        let (coordinator, settings) = try makeCoordinator(language: "de", models: models, queue: ModelWarmupQueue())
        coordinator.beginPrewarm { WarmupTestEngine() }
        await waitFor(latin.hasWaiter)

        settings.parakeetLanguage = "sv"
        await waitFor(coordinator.warmup == .ready)

        XCTAssertEqual(coordinator.warmup, .ready, "the Swedish warm-up must not wait for the Latin download")
        XCTAssertEqual(models.downloads, [.nemotron(languageCode: "de"), .nemotron(languageCode: "sv")])
        latin.open()
    }

    /// The retry the stall hint asks for recovers a hung load: only downloads are
    /// gated, so its own load starts beside the hung one instead of waiting for it.
    func testARetryAfterAStalledLoadLoadsWithoutWaitingForIt() async throws {
        for (language, _) in languages {
            let models = FakeCaptionModels()
            let stuck = models.holdLoad(0)
            let deadline = ManualDeadline()
            let queue = ModelWarmupQueue(sleep: deadline.sleep)
            let (coordinator, settings) = try makeCoordinator(language: language, models: models, queue: queue)
            coordinator.beginPrewarm { WarmupTestEngine() }
            await waitFor(stuck.hasWaiter && deadline.waiting == 1)
            deadline.pass()
            await waitFor(coordinator.warmup == .failed(stalledFailure))
            XCTAssertEqual(coordinator.warmup, .failed(stalledFailure), "\(language): test premise, the load stalled")

            await rebuild(coordinator, settings)
            await waitFor(coordinator.warmup == .ready)

            XCTAssertEqual(coordinator.warmup, .ready, "\(language): the retry must not wait for the hung load")
            XCTAssertTrue(stuck.hasWaiter, "\(language): the hung load must not be interrupted")
            XCTAssertEqual(models.mostLoadsAtOnce, 2, "\(language): the retry's load runs beside the hung one")
            stuck.open()
            await queue.run("test") {}
            XCTAssertEqual(coordinator.warmup, .ready, "\(language): the dropped warm-up must not write its outcome")
            deadline.pass()
        }
    }

    /// The load would download again, and outside the download gate, so it is not run.
    func testAFailedDownloadFallsBackWithoutLoading() async throws {
        for (language, _) in languages {
            let models = FakeCaptionModels()
            models.downloadError = URLError(.notConnectedToInternet)
            let (coordinator, _) = try makeCoordinator(language: language, models: models, queue: ModelWarmupQueue())
            let engine = WarmupTestEngine()
            coordinator.beginPrewarm { engine }
            await waitFor(!coordinator.warmup.isPreparing)

            XCTAssertEqual(coordinator.warmup, .ready, "\(language): the re-transcribe fallback")
            XCTAssertEqual(models.downloads.count, 1, language)
            XCTAssertEqual(models.loads, 0, "\(language): no streaming load after a failed download")
            XCTAssertEqual(engine.loadCount, 1, language)
        }
    }

    func testTheRealControllerDownloadsTheStreamingModels() {
        let controller = LiveTranscriptionCoordinator.makeDefaultController(
            engine: nil, captions: LiveCaptionsState(), engineLanguage: "de",
        ) { false }
        XCTAssertNotNil(controller.streamingModelDownload)
    }
}

/// Counts the caption model downloads and loads of every controller, and how many
/// ran at once; a call whose number has a gate waits on it.
@MainActor
final class FakeCaptionModels {
    private(set) var downloads: [LiveTranscriptionController.StreamingModel] = []
    var downloadError: (any Error)?
    private(set) var loads = 0
    private(set) var mostDownloadsAtOnce = 0
    private(set) var mostLoadsAtOnce = 0
    private var downloadsRunning = 0
    private var loadsRunning = 0
    private var downloadGates: [Int: MainActorGate] = [:]
    private var loadGates: [Int: MainActorGate] = [:]

    func holdDownload(_ call: Int) -> MainActorGate {
        let gate = MainActorGate()
        downloadGates[call] = gate
        return gate
    }

    func holdLoad(_ call: Int) -> MainActorGate {
        let gate = MainActorGate()
        loadGates[call] = gate
        return gate
    }

    func download(_ model: LiveTranscriptionController.StreamingModel) async throws {
        let call = downloads.count
        downloads.append(model)
        downloadsRunning += 1
        mostDownloadsAtOnce = max(mostDownloadsAtOnce, downloadsRunning)
        await downloadGates[call]?.wait()
        downloadsRunning -= 1
        if let downloadError { throw downloadError }
    }

    func load() async {
        let call = loads
        loads += 1
        loadsRunning += 1
        mostLoadsAtOnce = max(mostLoadsAtOnce, loadsRunning)
        await loadGates[call]?.wait()
        loadsRunning -= 1
    }
}

/// An EOU manager whose model load goes through `FakeCaptionModels`.
private actor CountingEouManager: EouStreamingAsrManaging {
    let models: FakeCaptionModels

    init(models: FakeCaptionModels) {
        self.models = models
    }

    func loadModels() async {
        await models.load()
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
