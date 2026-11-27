@testable import MeetingTranscriber
import XCTest

/// Live captions while cloud transcription is on: no re-transcribe route and
/// no local engine for the controller.
@MainActor
final class LiveTranscriptionCoordinatorCloudTests: XCTestCase {
    /// Mock collaborators, as in `LiveTranscriptionCoordinatorTests`: no model loads.
    private func mockControllerFactory() -> LiveTranscriptionCoordinator.ControllerFactory {
        { engine, captions, engineLanguage, verboseDiagnostics in
            LiveTranscriptionController(
                engine: engine,
                vad: FluidVAD(threshold: 0.5),
                captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(),
                engineLanguage: engineLanguage,
                eouSessionFactory: { MockEouManager() },
                nemotronPipelineFactory: { _, _, _ in
                    (RecordingCaptionPipeline(blockFirst: false), RecordingCaptionPipeline(blockFirst: false))
                },
                verboseDiagnostics: { verboseDiagnostics() },
            )
        }
    }

    private func countingControllerFactory() -> (LiveTranscriptionCoordinator.ControllerFactory, () -> Int) {
        let counter = ManagedCounter()
        let base = mockControllerFactory()
        let factory: LiveTranscriptionCoordinator.ControllerFactory = { engine, captions, lang, verbose in
            _ = counter.increment()
            return base(engine, captions, lang, verbose)
        }
        return (factory, { counter.value })
    }

    /// Cloud on with auto-detect: the gate's re-transcribe strategy becomes
    /// none, so the launch prewarm builds no controller (none loads the local
    /// model) and a recording gets no sinks.
    func testCloudOnWithAutoDetectBuildsNoController() async {
        let (factory, buildCount) = countingControllerFactory()
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            cloudTranscriptionEnabled: { true },
            verboseDiagnostics: { false },
            makeController: factory,
        )
        coordinator.beginPrewarm { MockStreamingEngine() }
        XCTAssertEqual(buildCount(), 0, "cloud on + auto-detect must not build a re-transcribe controller")

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)
        XCTAssertNil(recorder.micLiveSink)
        XCTAssertNil(recorder.appLiveSink)
    }

    /// Cloud on with English: the engine-independent EOU backend still runs, on
    /// a controller built without the local engine, so neither the language
    /// probe nor a failed load's re-transcribe fallback can load the model.
    func testCloudOnWithEnglishBuildsTheStreamingControllerWithoutTheEngine() async {
        var builds = 0
        var handedEngine: (any StreamingTranscribingEngine)?
        let base = mockControllerFactory()
        let factory: LiveTranscriptionCoordinator.ControllerFactory = { engine, captions, lang, verbose in
            builds += 1
            handedEngine = engine
            return base(engine, captions, lang, verbose)
        }
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            engineLanguage: { "en" },
            cloudTranscriptionEnabled: { true },
            verboseDiagnostics: { false },
            makeController: factory,
        )
        coordinator.beginPrewarm { MockStreamingEngine() }
        XCTAssertEqual(builds, 1, "test premise: the streaming controller was built")
        XCTAssertNil(handedEngine, "cloud on: the controller must not get the local engine")
        XCTAssertFalse(coordinator.captionsUseEngine)

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)
        XCTAssertNotNil(recorder.micLiveSink, "English streaming captions keep working with cloud on")
    }

    /// Like `makeEligibleCoordinator` (auto-detect, re-transcribe), plus a weak
    /// handle on the last controller built, so a test can see it was dropped.
    private func makeCloudToggleCoordinator(_ suiteName: String, isRecording: @escaping () -> Bool)
        -> (LiveTranscriptionCoordinator, AppSettings, () -> Int, () -> LiveTranscriptionController?) {
        // swiftlint:disable:next force_unwrapping
        let settings = AppSettings(defaults: DefaultsSuite.open(suiteName)!)
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = ""
        settings.liveTranscriptionEnabled = true
        let (base, buildCount) = countingControllerFactory()
        let last = WeakControllerBox()
        let factory: LiveTranscriptionCoordinator.ControllerFactory = { engine, captions, lang, verbose in
            let controller = base(engine, captions, lang, verbose)
            last.controller = controller
            return controller
        }
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { settings.liveTranscriptionEnabled },
            engineSupportsLive: { settings.transcriptionEngine.supportsLiveTranscription },
            engineLanguage: { settings.activeEngineLanguageOrNil },
            cloudTranscriptionEnabled: { settings.cloudTranscriptionEnabled },
            verboseDiagnostics: { false },
            makeController: factory,
        )
        let makeEngine: () -> (any TranscribingEngine)? = { MockStreamingEngine() }
        coordinator.beginPrewarm(engineProvider: makeEngine, isRecording: isRecording)
        return (coordinator, settings, buildCount, { last.controller })
    }

    private func settle() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }

    /// Switching cloud on while idle drops the re-transcribe controller (so
    /// nothing holds the local engine for captions) and builds none; switching
    /// it off re-warms as before.
    func testCloudToggleWhileIdleDropsThenRewarmsReTranscribeController() async {
        let suiteName = "LiveTxCoordTests-\(getpid())-\(UUID().uuidString)"
        defer { DefaultsSuite.remove(suiteName) }
        let (coordinator, settings, buildCount, lastController) = makeCloudToggleCoordinator(suiteName) { false }
        await settle() // let the launch prepare() finish and release its reference
        XCTAssertEqual(buildCount(), 1, "cloud off: prewarm builds the re-transcribe controller")
        XCTAssertNotNil(lastController())

        settings.cloudTranscriptionEnabled = true
        await settle()
        XCTAssertEqual(buildCount(), 1, "cloud on must not build a controller")
        XCTAssertNil(lastController(), "cloud on must drop the re-transcribe controller")
        let whileCloud = DualSourceRecorder()
        await coordinator.attachSinks(to: whileCloud)
        XCTAssertNil(whileCloud.micLiveSink, "cloud on: no captions for auto-detect")

        settings.cloudTranscriptionEnabled = false
        await settle()
        XCTAssertEqual(buildCount(), 2, "cloud off re-warms the re-transcribe controller")
        let afterCloud = DualSourceRecorder()
        await coordinator.attachSinks(to: afterCloud)
        XCTAssertNotNil(afterCloud.micLiveSink)
    }

    /// Switching cloud on mid-recording keeps the meeting's controller and
    /// drops it at the next idle flush, without building a new one.
    func testCloudOnDuringRecordingDropsControllerAtIdleFlush() async {
        let suiteName = "LiveTxCoordTests-\(getpid())-\(UUID().uuidString)"
        defer { DefaultsSuite.remove(suiteName) }
        var recording = true
        let (coordinator, settings, buildCount, lastController) = makeCloudToggleCoordinator(suiteName) {
            recording
        }
        await settle()
        XCTAssertEqual(buildCount(), 1)

        settings.cloudTranscriptionEnabled = true
        await settle()
        XCTAssertEqual(buildCount(), 1, "a mid-recording cloud switch must not rebuild")
        XCTAssertNotNil(lastController(), "the current meeting keeps its controller")

        recording = false
        await coordinator.flush()
        await settle()
        XCTAssertEqual(buildCount(), 1, "with cloud on the idle flush builds no controller")
        XCTAssertNil(lastController(), "the idle flush drops the re-transcribe controller")
    }
}

@MainActor
private final class WeakControllerBox {
    weak var controller: LiveTranscriptionController?
}
