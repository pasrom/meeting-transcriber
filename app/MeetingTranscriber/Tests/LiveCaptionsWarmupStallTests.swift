@testable import MeetingTranscriber
import XCTest

/// A caption warm-up whose load does not return: `prepare()` names the step it
/// is in, which the stall warning logs.
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
}
