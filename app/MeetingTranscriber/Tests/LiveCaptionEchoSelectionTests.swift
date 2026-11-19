import AudioTapLib
@testable import MeetingTranscriber
import XCTest

@MainActor
final class LiveCaptionEchoSelectionTests: XCTestCase {
    func testConfiguredCaptionChainSelectsCancellerOrGateFromFactory() async {
        for cancellationAvailable in [true, false] {
            let micPipeline = SelectionPipeline()
            let appPipeline = SelectionPipeline()
            let backend: LiveTranscriptionController.NemotronPipelineFactory = { _, _, _ in
                (micPipeline, appPipeline)
            }
            let factory: LiveCaptionEchoCanceller.Factory = {
                cancellationAvailable ? SelectionHop() : nil
            }
            let controller = LiveTranscriptionController(
                engine: nil,
                vad: FluidVAD(threshold: 0.5),
                captions: LiveCaptionsState(),
                speakerMatcher: FakeLiveSpeakerMatcher(),
                engineLanguage: "de",
                nemotronPipelineFactory: backend,
                echoCancellerFactory: factory,
            )
            await controller.prepare()
            let app = signal(frames: 120)
            controller.appSink(buffer(app, endingAt: 11.2))
            controller.micSink(buffer(Array(app[1600 ..< 17600]).map { $0 * 0.25 }, endingAt: 11.2))
            await controller.flush()

            let received = await micPipeline.samples
            if cancellationAvailable {
                XCTAssertEqual(received, Array(repeating: 9, count: 16000), "factory success must route through cancellation")
            } else {
                XCTAssertTrue(received.isEmpty, "factory nil must keep the acoustic echo gate")
            }
        }
    }

    func testStopFlushDeliversTheGatesShortTail() async {
        let noCanceller: LiveCaptionEchoCanceller.Factory = { nil }
        let micPipeline = SelectionPipeline()
        let appPipeline = SelectionPipeline()
        let backend: LiveTranscriptionController.NemotronPipelineFactory = { _, _, _ in
            (micPipeline, appPipeline)
        }
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "de",
            nemotronPipelineFactory: backend,
            echoCancellerFactory: noCanceller,
        )
        await controller.prepare()
        let speech = signal(frames: 50)
        controller.micSink(buffer(speech, endingAt: 11.2))
        await controller.flush()

        let received = await micPipeline.samples
        XCTAssertEqual(received, speech, "speech shorter than the gate's window must reach ASR at stop")
    }

    func testLanguageProbeInstallUsesCancellerFactory() async {
        let engine = SelectionLanguageEngine()
        let micPipeline = SelectionPipeline()
        let appPipeline = SelectionPipeline()
        let factory: LiveTranscriptionController.ReTranscribePipelineFactory = { channel, _, _ in
            channel == .mic ? micPipeline : appPipeline
        }
        let cancellerFactory: LiveCaptionEchoCanceller.Factory = { SelectionHop() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            reTranscribePipelineFactory: factory,
            speechDetector: \.self,
            echoCancellerFactory: cancellerFactory,
        )
        await controller.prepare()
        await controller.prepareForNextRecording()
        feedProbeSpeech(controller)
        await waitForDetection(engine)
        XCTAssertEqual(engine.detections, 1)
        await controller.waitForLanguageSwitch()
        controller.micSink(buffer(Array(repeating: 1, count: 8), endingAt: 12))
        await controller.flush()

        let received = await micPipeline.samples
        XCTAssertEqual(Array(received.suffix(8)), Array(repeating: 9, count: 8), "held-feed installation must use the selected canceller")
    }

    func testBindFeedsClearsStaleEchoReference() async {
        let noCanceller: LiveCaptionEchoCanceller.Factory = { nil }
        let micPipeline = SelectionPipeline()
        let appPipeline = SelectionPipeline()
        let backend: LiveTranscriptionController.NemotronPipelineFactory = { _, _, _ in
            (micPipeline, appPipeline)
        }
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "de",
            nemotronPipelineFactory: backend,
            echoCancellerFactory: noCanceller,
        )
        await controller.prepare()
        let app = signal(frames: 120)
        controller.appSink(buffer(app, endingAt: 11.2))
        await controller.bindFeeds()
        let mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
        controller.micSink(buffer(mic, endingAt: 11.2))
        await controller.flush()

        let received = await micPipeline.samples
        XCTAssertEqual(received, mic, "re-binding feeds must drop stale app audio from the echo reference")
    }

    func testFlushAndLanguageProbeClearEchoReference() async {
        let engine = SelectionLanguageEngine()
        let noCanceller: LiveCaptionEchoCanceller.Factory = { nil }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            speechDetector: \.self,
            echoCancellerFactory: noCanceller,
        )
        await controller.prepare()
        let app = signal(frames: 120)
        controller.appSink(buffer(app, endingAt: 11.2))
        XCTAssertFalse(controller.echoReference.samples(from: 10, to: 11.2).isEmpty)
        await controller.armLanguageProbe(recording: true)
        XCTAssertTrue(controller.echoReference.samples(from: 10, to: 11.2).isEmpty, "language probe arming must clear stale reference audio")

        controller.appSink(buffer(app, endingAt: 11.2))
        XCTAssertFalse(controller.echoReference.samples(from: 10, to: 11.2).isEmpty)
        await controller.flush()
        XCTAssertTrue(controller.echoReference.samples(from: 10, to: 11.2).isEmpty, "stop flush must release reference audio")
    }

    private func feedProbeSpeech(_ controller: LiveTranscriptionController) {
        for _ in 0 ..< 16 {
            controller.micSink(LiveAudioBuffer(
                samples: Array(repeating: 0.1, count: 4096), channelCount: 1, sampleRate: 16000, hostTime: 0,
            ))
        }
    }

    private func waitForDetection(_ engine: SelectionLanguageEngine) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.detections == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func buffer(_ samples: [Float], endingAt seconds: Double) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: samples, channelCount: 1, sampleRate: 16000,
            hostTime: SampleRateDriftDetector.secondsToMachTicks(seconds),
        )
    }

    private func signal(frames: Int) -> [Float] {
        (0 ..< frames * 160).map { index in
            let frame = index / 160
            let amplitude = Double((frame * 37 + 11) % 97 + 3) / 100
            return Float(amplitude * sin(Double(index) * 2 * .pi * 1000 / 16000))
        }
    }
}

private final class SelectionHop: LiveCaptionHopCancelling {
    let hopLength = 160
    func process(mic: [Float], reference _: [Float]) -> [Float] {
        Array(repeating: 9, count: mic.count)
    }
}

private actor SelectionPipeline: LiveCaptionPipeline {
    private(set) var samples: [Float] = []
    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {
        samples.append(contentsOf: buffer.samples)
    }

    func reset() {
        samples = []
    }

    func flush() {}
}

@MainActor
private final class SelectionLanguageEngine: StreamingTranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1
    var transcriptionProgress: Double = 1
    var supportsCaptionLanguageDetection = true
    private(set) var detections = 0

    func loadModel() {}
    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }

    func transcribeSamples(_: [Float]) -> String {
        ""
    }

    func detectLanguage(samples _: [Float]) -> CaptionLanguageDetection? {
        detections += 1
        return CaptionLanguageDetection(language: "de", probability: 0.95)
    }
}
