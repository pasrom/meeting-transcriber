import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Auto-detect captions across recordings: replay, EOU load reuse and failure, model kinds.
@MainActor
final class LiveTranscriptionAutoDetectLifecycleTests: XCTestCase, AutoDetectTesting {
    func testEnglishGreetingThenGermanReTranscribes() async {
        let harness = AutoDetectHarness()
        harness.engine.results = [
            CaptionLanguageDetection(language: "en", probability: 0.99),
            CaptionLanguageDetection(language: "de", probability: 0.95),
        ]
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        await passFirstEnglishWindow(harness, controller)
        harness.sendFourSeconds(to: controller)
        _ = await eventually { harness.engine.detectedSamples.count == 2 }
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        XCTAssertTrue(harness.eouManagers.isEmpty)
        await controller.flush()
    }

    func testReTranscribeReplaysOnlyTheNewestHeldSeconds() async {
        let harness = AutoDetectHarness()
        harness.engine.results = [CaptionLanguageDetection(language: "de", probability: 0.95)]
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        // 12 s of app audio held before the decision; only the newest 8 s are replayed.
        for second in 1 ... 12 {
            controller.appSink(LiveAudioBuffer(
                samples: [Float](repeating: Float(second), count: 16000),
                channelCount: 1, sampleRate: 16000, hostTime: 0,
            ))
        }
        harness.sendFourSeconds(to: controller)
        _ = await eventually { harness.engine.detectedSamples.count == 1 }
        await settleLanguageSwitch(controller)
        await controller.flush()
        let delivered = await harness.retranscription.app.samples
        XCTAssertEqual(delivered, (5 ... 12).map(Float.init))
    }

    func testNextRecordingStartDoesNotWaitForAnEouLoad() async {
        let harness = AutoDetectHarness()
        harness.engine.results = harness.confidentEnglish + harness.confidentEnglish
        let loadGate = ProbeGate()
        harness.eouLoadGate = loadGate
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        await passFirstEnglishWindow(harness, controller)
        harness.sendFourSeconds(to: controller)
        let loading = await loadGate.waitUntilEntered()
        XCTAssertTrue(loading)
        // The call drops and is rejoined while the EOU model is still loading.
        let restarted = await finishes {
            await controller.flush()
            await controller.prepareForNextRecording()
        }
        XCTAssertTrue(restarted, "the stop and the next start must not wait for the EOU load")
        await loadGate.release()
        guard restarted else { return }
        XCTAssertTrue(harness.captions.isDetectingLanguage)
        await passFirstEnglishWindow(harness, controller, detections: 3)
        harness.sendFourSeconds(to: controller)
        _ = await eventually { harness.engine.detectedSamples.count == 4 }
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
        XCTAssertEqual(harness.eouManagers.count, 2, "the stopped recording's load serves the next one")
        await controller.flush()
    }

    func testEouModelsLoadOnceAcrossEnglishRecordings() async {
        let harness = AutoDetectHarness()
        harness.engine.results = harness.confidentEnglish + harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        for recording in 0 ..< 2 {
            await controller.prepareForNextRecording()
            await passFirstEnglishWindow(harness, controller, detections: recording * 2 + 1)
            harness.sendFourSeconds(to: controller)
            _ = await eventually { harness.engine.detectedSamples.count == recording * 2 + 2 }
            await settleLanguageSwitch(controller)
            XCTAssertEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
            await controller.flush()
        }
        XCTAssertEqual(harness.eouManagers.count, 2)
        var loads = 0
        for manager in harness.eouManagers {
            loads += await manager.loadCount
        }
        XCTAssertEqual(loads, 2)
    }

    func testFailedEouLoadIsNotRetriedOnTheNextRecording() async {
        let harness = AutoDetectHarness()
        harness.eouFailureIndex = 0
        harness.engine.results = harness.confidentEnglish + harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        for recording in 0 ..< 2 {
            await controller.prepareForNextRecording()
            await passFirstEnglishWindow(harness, controller, detections: recording * 2 + 1)
            harness.sendFourSeconds(to: controller)
            _ = await eventually { harness.engine.detectedSamples.count == recording * 2 + 2 }
            await settleLanguageSwitch(controller)
            XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
            await controller.flush()
        }
        XCTAssertEqual(harness.eouManagers.count, 2, "a failed EOU load must not be retried per recording")
    }

    func testDroppingTheControllerClearsDetectingLanguage() async {
        let harness = AutoDetectHarness()
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        XCTAssertTrue(harness.captions.isDetectingLanguage, "test premise: the recording probes")
        controller.cancelPrepare()
        XCTAssertFalse(harness.captions.isDetectingLanguage)
    }

    /// The probe armed at idle holds no audio, so idle reads the same before and after a recording.
    func testIdleArmDoesNotReportDetection() async {
        let harness = AutoDetectHarness()
        let controller = harness.controller()
        await controller.prepare()
        XCTAssertEqual(controller.runtimeState, .detecting, "test premise: prepare() arms the probe")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        await controller.prepareForNextRecording()
        XCTAssertTrue(harness.captions.isDetectingLanguage)
        await controller.flush()
        XCTAssertFalse(harness.captions.isDetectingLanguage)
    }

    func testLoadedEngineIsNotReloadedForDetection() async {
        let harness = AutoDetectHarness()
        let controller = harness.controller()
        await controller.prepare()
        XCTAssertEqual(harness.engine.loadCount, 0)
    }

    /// A recording that starts before warm-up armed the probe; the load then shows an English-only model.
    func testEnglishOnlyModelEndsAProbeArmedBeforeTheLoad() async {
        let harness = AutoDetectHarness()
        harness.engine.modelState = .unloaded
        harness.engine.multilingualAfterLoad = false
        let controller = harness.controller()
        await controller.prepareForNextRecording()
        XCTAssertTrue(harness.captions.isDetectingLanguage, "test premise: the recording probes")
        await controller.prepare()
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        XCTAssertEqual(controller.runtimeState, .keeping, "the armed probe must be ended")
        harness.sendFourSeconds(to: controller)
        await controller.flush()
        XCTAssertTrue(harness.engine.detectedSamples.isEmpty)
        let delivered = await harness.retranscription.mic.samples
        XCTAssertEqual(delivered, (1 ... 16).map { Float($0) / 100 })
    }

    func testEnglishOnlyModelReTranscribesWithoutProbing() async {
        let harness = AutoDetectHarness()
        harness.engine.modelState = .unloaded
        harness.engine.multilingualAfterLoad = false
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        harness.sendFourSeconds(to: controller)
        await controller.flush()
        XCTAssertTrue(harness.engine.detectedSamples.isEmpty)
        XCTAssertEqual(harness.engine.loadCount, 1, "the fallback must not load the model again")
    }
}
