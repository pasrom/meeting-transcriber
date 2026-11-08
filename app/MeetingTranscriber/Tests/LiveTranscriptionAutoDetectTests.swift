import AudioTapLib
@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Recording-level language probing with model and VAD inference replaced by fakes.
@MainActor
final class LiveTranscriptionAutoDetectTests: XCTestCase, AutoDetectTesting {
    private struct DetectionFailure: Error {}

    func testEnglishInstallsBothEouSessionsAndReplaysHeldAudioInOrder() async {
        let harness = AutoDetectHarness()
        harness.engine.results = harness.confidentEnglish
        let detectionGate = ProbeGate()
        let preparationGate = ProbeGate()
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        XCTAssertTrue(harness.captions.isDetectingLanguage)
        XCTAssertTrue(harness.eouManagers.isEmpty)
        controller.appSink(buffer(0.4))
        await passFirstEnglishWindow(harness, controller)
        XCTAssertTrue(harness.eouManagers.isEmpty, "one English window must not load EOU")
        // Gated only now, so a first-window decision fails above instead of parking here.
        harness.eouLoadGate = preparationGate
        harness.engine.gate = detectionGate
        harness.sendFourSeconds(to: controller, markerOffset: 0.2)
        let detecting = await detectionGate.waitUntilEntered()
        XCTAssertTrue(detecting)
        controller.micSink(buffer(0.5))
        await detectionGate.release()
        let preparing = await preparationGate.waitUntilEntered()
        XCTAssertTrue(preparing)
        controller.micSink(buffer(0.6))
        controller.appSink(buffer(0.7))
        await preparationGate.release()
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        XCTAssertEqual(harness.eouManagers.count, 2)
        await controller.flush()
        let samples = await harness.eouManagers[0].samples
        guard samples.count == 34 * 4096 else {
            XCTFail("held microphone audio was not fully replayed")
            return
        }
        for index in 0 ..< 16 {
            XCTAssertEqual(samples[index * 4096], Float(index + 1) / 100)
            XCTAssertEqual(samples[(index + 16) * 4096], 0.2 + Float(index + 1) / 100)
        }
        XCTAssertEqual(samples[32 * 4096], 0.5)
        XCTAssertEqual(samples[33 * 4096], 0.6)
        let appSamples = await harness.eouManagers[1].samples
        guard appSamples.count == 2 * 4096 else {
            XCTFail("held app audio was not fully replayed")
            return
        }
        XCTAssertEqual(appSamples.first, 0.4)
        XCTAssertEqual(appSamples[4096], 0.7)
    }

    /// The coordinator keeps the engine loaded from this flag; the next recording probes on it again.
    func testEngineStaysInUseWhileDetectingAndAfterEnglishStreams() async {
        let harness = AutoDetectHarness()
        harness.engine.results = harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        XCTAssertTrue(controller.usesTranscriptionEngine, "detecting needs the engine")
        await passFirstEnglishWindow(harness, controller)
        harness.sendFourSeconds(to: controller)
        _ = await eventually { harness.engine.detectedSamples.count == 2 }
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Parakeet EOU · EN", "test premise: English streams")
        XCTAssertTrue(controller.usesTranscriptionEngine, "the next recording probes on the engine")
    }

    func testLateFinalFromPreviousRecordingIsDropped() async {
        let harness = AutoDetectHarness()
        harness.engine.results = Array(repeating: CaptionLanguageDetection(language: "id", probability: 0.99), count: 2)
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller)
        _ = await eventually { harness.engine.detectedSamples.count == 1 }
        await settleLanguageSwitch(controller)
        let previous = harness.sinks[.app]
        XCTAssertNotNil(previous, "test premise: the first recording re-transcribes")
        await controller.flush()
        await controller.prepareForNextRecording()
        previous?(.finalized(text: "late", audio: []))
        harness.sendFourSeconds(to: controller)
        _ = await eventually { harness.engine.detectedSamples.count == 2 }
        await settleLanguageSwitch(controller)
        harness.sinks[.app]?(.finalized(text: "new", audio: []))
        _ = await eventually { !harness.captions.recentFinals.isEmpty }
        XCTAssertEqual(harness.captions.recentFinals.map(\.text), ["new"])
    }

    func testNonEnglishReplaysHeldSpeechThenLiveAudio() async {
        let harness = AutoDetectHarness()
        harness.engine.results = [CaptionLanguageDetection(language: "de", probability: 0.91)]
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller)
        let detected = await eventually { harness.engine.detectedSamples.count == 1 }
        XCTAssertTrue(detected)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        XCTAssertTrue(harness.eouManagers.isEmpty)
        XCTAssertEqual(harness.retranscription.installCount, 2)
        controller.micSink(buffer(0.7))
        await controller.flush()
        let delivered = await harness.retranscription.mic.samples
        XCTAssertEqual(delivered, (1 ... 16).map { Float($0) / 100 } + [0.7])
    }

    func testLowConfidenceProbesFallBackForTheRecordingWithAutomaticLanguage() async {
        let harness = AutoDetectHarness()
        let attempts = CaptionLanguageProbeDecision.maxAttempts
        harness.engine.results = Array(
            repeating: CaptionLanguageDetection(language: "en", probability: 0.5), count: attempts,
        )
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        for attempt in 1 ... attempts {
            harness.sendFourSeconds(to: controller)
            let detected = await eventually { harness.engine.detectedSamples.count == attempt }
            XCTAssertTrue(detected)
            await settleLanguageSwitch(controller)
        }
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        harness.sendFourSeconds(to: controller)
        await controller.flush()
        XCTAssertEqual(harness.engine.detectedSamples.count, attempts, "one decision per recording")
    }

    func testOtherChannelCanRetryAfterMicProbeWasLowConfidence() async {
        let harness = AutoDetectHarness()
        let gate = ProbeGate()
        harness.engine.gate = gate
        harness.engine.results = [
            CaptionLanguageDetection(language: "en", probability: 0.5),
        ] + harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller, channel: .mic)
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        controller.appSink(buffer(0.21))
        await gate.release()
        await settleLanguageSwitch(controller)
        XCTAssertTrue(harness.captions.isDetectingLanguage)
        // The other channel must remain eligible after the mic probe retries.
        harness.sendFourSeconds(to: controller, channel: .app, markerOffset: 0.2)
        let retried = await eventually { harness.engine.detectedSamples.count == 2 }
        XCTAssertTrue(retried)
        await settleLanguageSwitch(controller)
        harness.sendFourSeconds(to: controller, channel: .app, markerOffset: 0.4)
        _ = await eventually { harness.engine.detectedSamples.count == 3 }
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
        XCTAssertEqual(harness.engine.detectedSamples.count, 3)
        await controller.flush()
    }

    func testSecondEouModelFailureFallsBackToLiveRetranscription() async {
        let harness = AutoDetectHarness()
        harness.eouFailureIndex = 1
        harness.engine.results = harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        await passFirstEnglishWindow(harness, controller)
        harness.sendFourSeconds(to: controller)
        let detected = await eventually { harness.engine.detectedSamples.count == 2 }
        XCTAssertTrue(detected)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.eouManagers.count, 2)
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        controller.micSink(buffer(0.7))
        await controller.flush()
        let delivered = await harness.retranscription.mic.samples
        // 8.2 s held over two windows; the newest 8 s are replayed before live audio.
        XCTAssertEqual(delivered, ((2 ... 16).map { Float($0) / 100 }) + (1 ... 16).map { Float($0) / 100 } + [0.7])
    }

    func testNextRecordingStartsFreshDetection() async {
        let harness = AutoDetectHarness()
        harness.engine.results = [
            CaptionLanguageDetection(language: "de", probability: 0.95),
        ] + harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller)
        let first = await eventually { harness.engine.detectedSamples.count == 1 }
        XCTAssertTrue(first)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        await controller.flush()

        await controller.prepareForNextRecording()
        XCTAssertTrue(harness.captions.isDetectingLanguage)
        await passFirstEnglishWindow(harness, controller, detections: 2)
        harness.sendFourSeconds(to: controller)
        let second = await eventually { harness.engine.detectedSamples.count == 3 }
        XCTAssertTrue(second)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
        await controller.flush()
    }

    func testUnsupportedDetectionFallsBackWithoutAnotherProbe() async {
        let harness = AutoDetectHarness()
        harness.engine.results = [nil]
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller)
        let detected = await eventually { harness.engine.detectedSamples.count == 1 }
        XCTAssertTrue(detected)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        harness.sendFourSeconds(to: controller)
        await controller.flush()
        XCTAssertEqual(harness.engine.detectedSamples.count, 1)
    }

    func testFirstChannelToReachSpeechThresholdWins() async {
        let harness = AutoDetectHarness()
        harness.engine.results = harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        controller.micSink(buffer(0.9))
        harness.sendFourSeconds(to: controller, channel: .app)
        let detected = await eventually { harness.engine.detectedSamples.count == 1 }
        XCTAssertTrue(detected)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.engine.detectedSamples.first?.first, 0.01)
        harness.sendFourSeconds(to: controller)
        _ = await eventually { harness.engine.detectedSamples.count == 2 }
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
        await controller.flush()
    }

    func testSilenceDoesNotCountTowardFourSecondsOfSpeech() async {
        let harness = AutoDetectHarness()
        let silenceGate = ProbeGate()
        harness.speechDetector = { samples in
            if samples.first == 0 {
                await silenceGate.park()
                return []
            }
            return samples
        }
        harness.engine.results = [CaptionLanguageDetection(language: "de", probability: 0.95)]
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        // Wait until this whole buffer is dequeued before sending speech:
        // an instantaneous eight-second burst exceeds the normal five-second feed.
        controller.micSink(LiveAudioBuffer(
            samples: [Float](repeating: 0, count: 16 * 4096),
            channelCount: 1, sampleRate: 16000, hostTime: 0,
        ))
        let consumed = await silenceGate.waitUntilEntered()
        XCTAssertTrue(consumed)
        XCTAssertTrue(harness.engine.detectedSamples.isEmpty)
        await silenceGate.release()
        for _ in 0 ..< 16 {
            controller.micSink(buffer(0.3))
        }
        let detected = await eventually { harness.engine.detectedSamples.count == 1 }
        XCTAssertTrue(detected)
        guard let detectedSamples = harness.engine.detectedSamples.first else {
            XCTFail("speech did not reach language detection")
            return
        }
        XCTAssertEqual(detectedSamples.count, 64000)
        XCTAssertTrue(detectedSamples.allSatisfy { $0 == 0.3 })
        await settleLanguageSwitch(controller)
        await controller.flush()
    }

    func testRetranscriptionDoesNotStartBeforeSpeechThreshold() async {
        let harness = AutoDetectHarness()
        let chunks = ChunkCounter()
        harness.speechDetector = { samples in
            chunks.increment()
            return samples
        }
        harness.engine.results = [CaptionLanguageDetection(language: "de", probability: 0.95)]
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        for _ in 0 ..< 15 {
            controller.micSink(buffer(0.3))
        }
        // The probe must have seen all 15 chunks, or the negatives below pass vacuously.
        let consumed = await eventually { chunks.count == 15 }
        XCTAssertTrue(consumed)
        XCTAssertTrue(harness.captions.isDetectingLanguage)
        XCTAssertTrue(harness.engine.detectedSamples.isEmpty)
        XCTAssertEqual(harness.retranscription.installCount, 0)
        XCTAssertEqual(harness.engine.transcribeCallCount, 0)
        controller.micSink(buffer(0.3))
        let detected = await eventually { harness.engine.detectedSamples.count == 1 }
        XCTAssertTrue(detected)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.retranscription.installCount, 2)
        await controller.flush()
    }

    func testDetectionFailureFallsBackWithoutAnotherProbe() async {
        let harness = AutoDetectHarness()
        harness.engine.error = DetectionFailure()
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller)
        let detected = await eventually { harness.engine.detectedSamples.count == 1 }
        XCTAssertTrue(detected)
        await settleLanguageSwitch(controller)
        XCTAssertEqual(harness.captions.activeBackend, "Re-transcribe")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        await controller.flush()
    }

    func testVadFailureFallsBackWithoutDetection() async {
        let harness = AutoDetectHarness()
        harness.speechDetector = { _ in throw DetectionFailure() }
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller)
        let decided = await eventually { harness.captions.activeBackend == "Re-transcribe" }
        XCTAssertTrue(decided)
        XCTAssertTrue(harness.engine.detectedSamples.isEmpty)
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        await controller.flush()
    }

    func testStopDuringDetectionCannotPublishLateBackend() async {
        let harness = AutoDetectHarness()
        let gate = ProbeGate()
        harness.engine.gate = gate
        harness.engine.results = harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        harness.sendFourSeconds(to: controller)
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        let stopping = controller.beginFlush()
        await gate.release()
        await stopping.value
        await settleLanguageSwitch(controller)
        XCTAssertNotEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        XCTAssertTrue(harness.eouManagers.isEmpty)
        XCTAssertTrue(harness.engine.cancelledDuringDetection)
    }

    func testStopDuringEouPreparationCannotPublishLateBackend() async {
        let harness = AutoDetectHarness()
        let gate = ProbeGate()
        harness.eouLoadGate = gate
        harness.engine.results = harness.confidentEnglish
        let controller = harness.controller()
        await controller.prepare()
        await controller.prepareForNextRecording()
        await passFirstEnglishWindow(harness, controller)
        harness.sendFourSeconds(to: controller)
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        let stopped = await finishes { await controller.beginFlush().value }
        XCTAssertTrue(stopped, "the stop must not wait for the EOU load")
        XCTAssertFalse(harness.captions.isDetectingLanguage)
        await gate.release()
        await settleLanguageSwitch(controller)
        XCTAssertNotEqual(harness.captions.activeBackend, "Parakeet EOU · EN")
    }
}
