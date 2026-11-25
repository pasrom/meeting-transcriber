import AudioTapLib
@testable import MeetingTranscriber
import XCTest

@MainActor
final class LiveCaptionEchoSelectionTests: XCTestCase {
    func testCaptionChainCancelsOnlyWithEchoCancellationSettingOn() async {
        for enabled in [true, false] {
            let micPipeline = SelectionPipeline()
            let controller = makeController(micPipeline: micPipeline) { SelectionHop() }
            controller.echoCancellationEnabled = { enabled }
            await controller.prepare()
            XCTAssertEqual(controller.micCaptionChain != nil, enabled, "setting off must bind the mic with no processor")
            let app = signal(frames: 120)
            let mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
            controller.appSink(buffer(app, endingAt: 11.2))
            controller.micSink(buffer(mic, endingAt: 11.2))
            await controller.flush()

            let received = await micPipeline.samples
            XCTAssertEqual(received, enabled ? Array(repeating: 9, count: 16000) : mic)
        }
    }

    func testEchoCancellationSettingIsReadAtEachCaptionStart() async {
        var enabled = false
        let controller = makeController(micPipeline: SelectionPipeline()) { SelectionHop() }
        controller.echoCancellationEnabled = { enabled }
        await controller.prepare()
        XCTAssertNil(controller.micCaptionChain)
        enabled = true
        await controller.bindFeeds()
        XCTAssertNotNil(controller.micCaptionChain, "turning the setting on must apply at the next caption start")
    }

    func testSettingOffRetainsNoAppAudioForTheReference() async {
        for enabled in [false, true] {
            let controller = makeController(micPipeline: SelectionPipeline()) { SelectionHop() }
            controller.echoCancellationEnabled = { enabled }
            await controller.prepare()
            controller.appSink(buffer(signal(frames: 120), endingAt: 11.2))
            XCTAssertEqual(controller.echoReference.end != nil, enabled, "with no canceller nothing reads the reference")
        }
    }

    func testDisablingSettingDuringLanguageProbeClearsReference() async {
        var enabled = true
        let engine = SelectionLanguageEngine()
        let cancellerFactory: LiveCaptionEchoCanceller.Factory = { SelectionHop() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            speechDetector: \.self,
            echoCancellerFactory: cancellerFactory,
        )
        controller.echoCancellationEnabled = { enabled }
        await controller.prepare()
        await controller.armLanguageProbe(recording: true)
        controller.appSink(buffer(signal(frames: 120), endingAt: 11.2))
        XCTAssertNotNil(controller.echoReference.end, "reference collects app audio while the probe holds the mic")

        enabled = false
        _ = controller.makeMicCaptionPipeline(SelectionPipeline())
        XCTAssertNil(controller.echoReference.end, "turning echo cancellation off during a probe must clear held reference audio")
        controller.appSink(buffer(signal(frames: 120), endingAt: 12.4))
        XCTAssertNil(controller.echoReference.end, "reference must stop collecting once echo cancellation is off")
    }

    func testDefaultFactoryCancelsEchoWithBundledModel() async throws {
        _ = try requireLocalVQEModel()
        let micPipeline = SelectionPipeline()
        let controller = makeController(micPipeline: micPipeline, factory: nil)
        controller.echoCancellationEnabled = { true }
        await controller.prepare()
        let farEnd = EchoTestAudio.speechLike(seconds: 4, seed: 11)
        let mic = EchoTestAudio.bleed(farEnd, delayMs: 0, gain: 0.5)
        for first in stride(from: 0, to: farEnd.count, by: 1600) {
            let end = 10 + Double(first + 1600) / 16000
            controller.appSink(buffer(Array(farEnd[first ..< first + 1600]), endingAt: end))
            controller.micSink(buffer(Array(mic[first ..< first + 1600]), endingAt: end))
        }
        await controller.flush()

        let received = await micPipeline.samples
        XCTAssertEqual(received.count, mic.count)
        // Ignore the first second: the canceller converges from zero state.
        let settled = EchoTestAudio.rate
        let reduction = AudioMixer.rmsDecibels(samples: Array(mic[settled...]))
            - AudioMixer.rmsDecibels(samples: Array(received[settled...]))
        XCTAssertGreaterThan(reduction, EchoReductionVerdict.minReductionDb, "the default factory must cancel with LocalVQE")
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
        controller.echoCancellationEnabled = { true }
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
        let controller = makeController(micPipeline: SelectionPipeline()) { nil }
        controller.echoCancellationEnabled = { true }
        await controller.prepare()
        controller.appSink(buffer(signal(frames: 120), endingAt: 11.2))
        XCTAssertNotNil(controller.echoReference.end)
        await controller.bindFeeds()
        XCTAssertNil(controller.echoReference.end, "re-binding feeds must drop stale app audio from the echo reference")
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
        controller.echoCancellationEnabled = { true }
        await controller.prepare()
        let app = signal(frames: 120)
        controller.appSink(buffer(app, endingAt: 11.2))
        XCTAssertNotNil(controller.echoReference.end)
        await controller.armLanguageProbe(recording: true)
        XCTAssertNil(controller.echoReference.end, "language probe arming must clear stale reference audio")

        controller.appSink(buffer(app, endingAt: 11.2))
        XCTAssertNotNil(controller.echoReference.end)
        await controller.flush()
        XCTAssertNil(controller.echoReference.end, "stop flush must release reference audio")
    }

    private func makeController(
        micPipeline: SelectionPipeline, factory: LiveCaptionEchoCanceller.Factory?,
    ) -> LiveTranscriptionController {
        let backend: LiveTranscriptionController.NemotronPipelineFactory = { _, _, _ in
            (micPipeline, SelectionPipeline())
        }
        guard let factory else {
            return LiveTranscriptionController(
                engine: nil, vad: FluidVAD(threshold: 0.5), captions: LiveCaptionsState(),
                speakerMatcher: FakeLiveSpeakerMatcher(), engineLanguage: "de", nemotronPipelineFactory: backend,
            )
        }
        return LiveTranscriptionController(
            engine: nil, vad: FluidVAD(threshold: 0.5), captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(), engineLanguage: "de", nemotronPipelineFactory: backend,
            echoCancellerFactory: factory,
        )
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

    func reset() {}
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
