import AudioTapLib
@testable import MeetingTranscriber
import XCTest

@MainActor
final class LiveCaptionEchoGateTests: XCTestCase {
    func testSkipsDelayedScaledMicrophoneEchoBeforeASR() async {
        let pipeline = EchoGateRecordingPipeline()
        let reference = LiveCaptionEchoReference()
        let gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
        let app = signal(frames: 120)
        reference.append(buffer(app, endingAt: 11.2))
        let mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }

        await gate.ingest(buffer(mic, endingAt: 11.2))
        await gate.flush()

        let received = await pipeline.samples
        XCTAssertTrue(received.isEmpty, "a 100 ms delayed acoustic copy must never reach ASR")
    }

    func testSkipsEchoDeliveredInCaptureSizedBuffers() async {
        let pipeline = EchoGateRecordingPipeline()
        let reference = LiveCaptionEchoReference()
        let gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
        let app = signal(frames: 120)
        for offset in stride(from: 0, to: app.count, by: 176) {
            let end = min(offset + 176, app.count)
            reference.append(buffer(Array(app[offset ..< end]), endingAt: 10 + Double(end) / 16000))
        }
        let mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
        for offset in stride(from: 0, to: mic.count, by: 1360) {
            let end = min(offset + 1360, mic.count)
            await gate.ingest(buffer(Array(mic[offset ..< end]), endingAt: 10.2 + Double(end) / 16000))
        }
        await gate.flush()

        let received = await pipeline.samples
        XCTAssertTrue(received.isEmpty, "capture buffer sizes must not change the echo decision")
    }

    func testKeepsMicrophoneOnlySpeech() async {
        let pipeline = EchoGateRecordingPipeline()
        let gate = LiveCaptionEchoGate(pipeline: pipeline)
        let mic = signal(frames: 100)

        await gate.ingest(buffer(mic, endingAt: 11.2))
        await gate.flush()

        let received = await pipeline.samples
        XCTAssertEqual(received, mic)
    }

    func testKeepsSoftLocalSpeechOverConcurrentEcho() async {
        let pipeline = EchoGateRecordingPipeline()
        let reference = LiveCaptionEchoReference()
        let gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
        let app = signal(frames: 120)
        reference.append(buffer(app, endingAt: 11.2))
        var mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
        for i in 4800 ..< 11200 {
            mic[i] += Float(sin(Double(i) * 2 * .pi * 370 / 16000)) * 0.12
        }

        await gate.ingest(buffer(mic, endingAt: 11.2))
        await gate.flush()

        let received = await pipeline.samples
        XCTAssertEqual(received, mic, "double talk must retain the entire microphone window")
    }

    func testKeepsBriefLocalBurstThatFitsWholeWindowWaveformCorrelation() async {
        let pipeline = EchoGateRecordingPipeline()
        let reference = LiveCaptionEchoReference()
        let gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
        let app = signal(frames: 120)
        reference.append(buffer(app, endingAt: 11.2))
        var mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
        // One 50 ms block with extra energy keeps whole-window waveform r^2 above 0.95,
        // so only the per-block gain check protects a brief local interjection.
        for i in 0 ..< 800 {
            mic[i] *= 1.5
        }

        await gate.ingest(buffer(mic, endingAt: 11.2))
        await gate.flush()

        let received = await pipeline.samples
        XCTAssertEqual(received, mic, "every 50 ms block must fit the echo gain before suppressing")
    }

    func testKeepsLocalSpeechWithSameEnvelopeAsRemote() async {
        let pipeline = EchoGateRecordingPipeline()
        let reference = LiveCaptionEchoReference()
        let gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
        let app = signal(frames: 120)
        reference.append(buffer(app, endingAt: 11.2))
        var mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
        for i in mic.indices {
            let frame = (i + 1600) / 160
            let amplitude = Double((frame * 37 + 11) % 97 + 3) / 100
            let phase = Double(i) * 2 * .pi * 370 / 16000
            let local = Float(amplitude * sin(phase)) * 0.15
            mic[i] += local
        }

        await gate.ingest(buffer(mic, endingAt: 11.2))
        await gate.flush()

        let received = await pipeline.samples
        XCTAssertEqual(received, mic, "envelope coincidence cannot establish acoustic identity")
    }

    func testMissingStaleAndDiscontinuousReferenceKeepsMicrophoneSpeech() async {
        let app = signal(frames: 120)
        let mic = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
        for items in [
            [buffer(app, endingAt: 4)],
            [buffer(Array(app.prefix(8000)), endingAt: 10.5), buffer(Array(app.suffix(8000)), endingAt: 11.2)],
        ] {
            let pipeline = EchoGateRecordingPipeline()
            let reference = LiveCaptionEchoReference()
            let gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
            for item in items {
                reference.append(item)
            }
            await gate.ingest(buffer(mic, endingAt: 11.2))
            await gate.flush()
            let received = await pipeline.samples
            XCTAssertEqual(received, mic)
        }
    }

    func testFirstSuppressedWindowFlushesAndResetsPipelineOnce() async {
        let pipeline = EchoGateRecordingPipeline()
        let reference = LiveCaptionEchoReference()
        let gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
        let app = signal(frames: 220)
        reference.append(buffer(app, endingAt: 12.2))
        let echo1 = Array(app[1600 ..< 17600]).map { $0 * 0.25 }
        let echo2 = Array(app[17600 ..< 33600]).map { $0 * 0.25 }

        await gate.ingest(buffer(echo1, endingAt: 11.2))
        await gate.ingest(buffer(echo2, endingAt: 12.2))

        let received = await pipeline.samples
        let flushes = await pipeline.flushes
        let resets = await pipeline.resets
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(flushes, 1, "first suppressed window must flush buffered speech once")
        XCTAssertEqual(resets, 1, "consecutive suppressed windows must not repeatedly reset the pipeline")
    }

    func testGapDeliversPendingTailAndResetsPipeline() async {
        let pipeline = EchoGateRecordingPipeline()
        let gate = LiveCaptionEchoGate(pipeline: pipeline)
        let first = signal(frames: 30)
        let second = signal(frames: 30)

        await gate.ingest(buffer(first, endingAt: 10.3))
        await gate.ingest(buffer(second, endingAt: 11.0))

        let received = await pipeline.samples
        let flushes = await pipeline.flushes
        let resets = await pipeline.resets
        XCTAssertEqual(received, first, "tail before a discontinuity must reach ASR before the reset")
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(resets, 1)
    }

    func testStopFlushDeliversShortTailAndZeroTimestampBuffersUnchanged() async {
        for timestamp in [0.0, 11.2] {
            let pipeline = EchoGateRecordingPipeline()
            let gate = LiveCaptionEchoGate(pipeline: pipeline)
            let mic = signal(frames: 40)
            await gate.ingest(buffer(mic, endingAt: timestamp))
            await gate.flush()
            let received = await pipeline.samples
            let flushes = await pipeline.flushes
            XCTAssertEqual(received, mic)
            XCTAssertEqual(flushes, 1)
        }
        let pipeline = EchoGateRecordingPipeline()
        let gate = LiveCaptionEchoGate(pipeline: pipeline)
        let mic = signal(frames: 40)
        await gate.ingest(LiveAudioBuffer(samples: mic, channelCount: 1, sampleRate: 16000, hostTime: 1))
        await gate.flush()
        let received = await pipeline.samples
        XCTAssertEqual(received, mic, "small positive hostTime must not trap on timestamp clamping")
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

private actor EchoGateRecordingPipeline: LiveCaptionPipeline {
    private(set) var samples: [Float] = []
    private(set) var flushes = 0
    private(set) var resets = 0

    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {
        samples.append(contentsOf: buffer.samples)
    }

    func reset() {
        resets += 1
    }

    func flush() {
        flushes += 1
    }
}
