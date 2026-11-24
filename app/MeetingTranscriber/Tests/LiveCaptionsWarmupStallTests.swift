@testable import MeetingTranscriber
import XCTest

/// A caption warm-up whose load does not return: `prepare()` names the step it
/// is in, which the stall warning logs, and at the queue's deadline the warm-up
/// shows as failed with the retry hint, and a retry does not wait for it.
@MainActor
final class LiveCaptionsWarmupStallTests: XCTestCase {
    private func makeController(
        engine: (any StreamingTranscribingEngine)? = nil,
        speakerMatcher: any LiveSpeakerMatching = FakeLiveSpeakerMatcher(),
        engineLanguage: String? = nil,
        eouSessionFactory: @escaping LiveTranscriptionController.EouSessionFactory = { MockEouManager() },
    ) -> LiveTranscriptionController {
        LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: speakerMatcher,
            engineLanguage: engineLanguage,
            eouSessionFactory: eouSessionFactory,
        )
    }

    // MARK: - Naming the step

    func testPrepareNamesTheSpeakerMatcherAndEouStepsWhileTheyRun() async {
        let matcher = GatedSpeakerMatcher(gate: AsyncGate())
        let eouGate = AsyncGate()
        let controller = makeController(speakerMatcher: matcher, engineLanguage: "en") { GatedEouManager(gate: eouGate) }
        let prepare = Task { await controller.prepare() }

        await waitFor { await matcher.gate.hasWaiter }
        XCTAssertEqual(controller.prepareStep, "speaker matcher")
        await matcher.gate.open()
        await waitFor { await eouGate.hasWaiter }
        XCTAssertEqual(controller.prepareStep, "EOU models, mic channel")
        await eouGate.open()
        await prepare.value

        XCTAssertNil(controller.prepareStep, "no step once prepare() returned")
    }

    func testPrepareNamesTheEngineLoadWhileItRuns() async {
        for detectsLanguage in [false, true] {
            let engine = WarmupTestEngine(gated: true)
            engine.detectsLanguage = detectsLanguage
            let controller = makeController(engine: engine)
            let prepare = Task { await controller.prepare() }

            await waitFor(engine.gate.hasWaiter)
            XCTAssertEqual(controller.prepareStep, detectsLanguage ? "engine load for language detection" : "engine load")
            engine.gate.open()
            await prepare.value
        }
    }

    func testPrepareNamesTheNemotronLoadWhileItRuns() async {
        let gate = AsyncGate()
        let nemotron: LiveTranscriptionController.NemotronPipelineFactory = { _, _, _ in
            await gate.wait()
            throw URLError(.timedOut)
        }
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "de",
            nemotronPipelineFactory: nemotron,
        )
        let prepare = Task { await controller.prepare() }

        await waitFor { await gate.hasWaiter }
        XCTAssertEqual(controller.prepareStep, "Nemotron models")
        await gate.open()
        await prepare.value
    }

    // MARK: - Recovering from a stalled warm-up

    /// Captions on over real settings, so turning them off and on rebuilds the controller.
    private func makeSettingsCoordinator(
        warmupQueue: ModelWarmupQueue,
    ) throws -> (LiveTranscriptionCoordinator, AppSettings) {
        let suiteName = "LiveCaptionsWarmupStallTests-\(getpid())-\(UUID().uuidString)"
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
            makeController: { engine, captions, language, verbose in
                LiveTranscriptionController(
                    engine: engine,
                    vad: FluidVAD(threshold: 0.5),
                    captions: captions,
                    speakerMatcher: FakeLiveSpeakerMatcher(),
                    engineLanguage: language,
                    verboseDiagnostics: verbose,
                )
            },
            warmupQueue: warmupQueue,
        )
        return (coordinator, settings)
    }

    private var stalledFailure: String {
        LiveTranscriptionCoordinator.stalledFailure(after: ModelWarmupQueue.defaultStallDeadline)
    }

    func testAWarmupStillLoadingAtTheDeadlineFailsWithTheRetryHintAndStillFinishes() async throws {
        let deadline = ManualDeadline()
        let (coordinator, _) = try makeSettingsCoordinator(warmupQueue: ModelWarmupQueue(sleep: deadline.sleep))
        let engine = WarmupTestEngine(gated: true)
        coordinator.beginPrewarm { engine }
        await waitFor(engine.gate.hasWaiter && deadline.waiting == 1)
        XCTAssertTrue(coordinator.warmup.isPreparing, "test premise")

        deadline.pass()
        await waitFor(!coordinator.warmup.isPreparing)

        XCTAssertEqual(coordinator.warmup, .failed(stalledFailure))
        XCTAssertEqual(stalledFailure, "Loading the caption models has not finished 5 minutes after it started.")
        XCTAssertEqual(
            LiveTranscriptionCoordinator.stalledFailure(after: .seconds(90)),
            "Loading the caption models has not finished 90 seconds after it started.",
        )
        XCTAssertEqual(coordinator.warmup.settingsText?.hasSuffix("\nTurn live captions off and on to retry."), true)
        engine.gate.open()
        await waitFor(coordinator.warmup == .ready)
        XCTAssertEqual(coordinator.warmup, .ready, "the load was left running, and its outcome replaces the failure")
    }

    func testTurningCaptionsOffAndOnAfterAStallDoesNotWaitForTheStuckLoad() async throws {
        let deadline = ManualDeadline()
        let queue = ModelWarmupQueue(sleep: deadline.sleep)
        let (coordinator, settings) = try makeSettingsCoordinator(warmupQueue: queue)
        let stuck = WarmupTestEngine(gated: true)
        var engine = stuck
        coordinator.beginPrewarm { engine }
        await waitFor(stuck.gate.hasWaiter && deadline.waiting == 1)
        deadline.pass()
        await waitFor(coordinator.warmup == .failed(stalledFailure))
        XCTAssertEqual(coordinator.warmup, .failed(stalledFailure), "test premise: the warm-up stalled")

        let fresh = WarmupTestEngine()
        engine = fresh
        settings.liveTranscriptionEnabled = false
        await waitFor(coordinator.warmup == .idle)
        settings.liveTranscriptionEnabled = true
        await waitFor(coordinator.warmup == .ready, timeout: .seconds(5))

        XCTAssertEqual(coordinator.warmup, .ready, "the retry must not queue behind the stuck load")
        XCTAssertEqual(fresh.loadCount, 1)
        XCTAssertTrue(stuck.gate.hasWaiter, "the stuck load must not be interrupted")
        stuck.gate.open()
        await queue.run("test") {}
        XCTAssertEqual(coordinator.warmup, .ready, "the dropped warm-up must not write its outcome")
        deadline.pass()
    }

    /// The deadline of a controller already dropped must not fail its successor's warm-up.
    func testADroppedWarmupReachingTheDeadlineLeavesItsSuccessorPreparing() async throws {
        let deadline = ManualDeadline()
        let queue = ModelWarmupQueue(sleep: deadline.sleep)
        let (coordinator, settings) = try makeSettingsCoordinator(warmupQueue: queue)
        let stuck = WarmupTestEngine(gated: true)
        var engine = stuck
        coordinator.beginPrewarm { engine }
        await waitFor(stuck.gate.hasWaiter && deadline.waiting == 1)
        let successor = WarmupTestEngine(gated: true)
        engine = successor
        settings.liveTranscriptionEnabled = false
        await waitFor(coordinator.warmup == .idle)
        settings.liveTranscriptionEnabled = true
        await waitFor(coordinator.warmup.isPreparing)

        deadline.pass()
        await waitFor(successor.gate.hasWaiter)

        XCTAssertTrue(successor.gate.hasWaiter, "test premise: the successor runs once the stuck load stalled")
        XCTAssertTrue(coordinator.warmup.isPreparing, "the stale deadline must not fail the successor")
        successor.gate.open()
        await waitFor(coordinator.warmup == .ready)
        stuck.gate.open()
        await queue.run("test") {}
        deadline.pass()
    }
}
