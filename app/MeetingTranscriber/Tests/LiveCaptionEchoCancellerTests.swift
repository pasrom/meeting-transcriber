import AudioTapLib
@testable import MeetingTranscriber
import os
import XCTest

@MainActor
final class LiveCaptionEchoCancellerTests: XCTestCase {
    func testCancelledHopsReachASRWithContiguousHostTimes() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer(Array(repeating: 2, count: 16), endingAt: start + 16.0 / 16000))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, app in zip(mic, app).map { $0 + $1 } }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 3), endingAt: start + 3.0 / 16000)) { 0 }
        await canceller.ingest(buffer(Array(repeating: 1, count: 13), endingAt: start + 16.0 / 16000)) { 0 }
        await canceller.flush()

        let received = await pipeline.buffers
        XCTAssertEqual(received.map(\.samples), [Array(repeating: 3, count: 8), Array(repeating: 3, count: 8)])
        XCTAssertEqual(
            received.map(\.hostTime),
            [8, 16].map { SampleRateDriftDetector.secondsToMachTicks(start + Double($0) / 16000) },
        )
        XCTAssertEqual(calls.references, [Array(repeating: 2, count: 8), Array(repeating: 2, count: 8)])
    }

    func testReferenceUsesSameHostSpanAndFillsMissingMiddleWithSilence() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer([1, 2, 3], endingAt: start + 3.0 / 16000))
        reference.append(buffer([7, 8], endingAt: start + 8.0 / 16000))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 5, count: 8), endingAt: start + 8.0 / 16000)) { 0 }
        await canceller.flush()

        XCTAssertEqual(calls.references, [[1, 2, 3, 0, 0, 0, 7, 8]])
    }

    func testLateCallbackStampDoesNotShiftReferenceAlignment() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer((0 ..< 1600).map(Float.init), endingAt: start + 0.1))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 8.0 / 16000)) { 0 }
        // Callback delivered 50 ms late: its stamp is not when the audio was captured.
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 16.0 / 16000 + 0.05)) { 0 }
        await canceller.flush()

        XCTAssertEqual(calls.references, [(0 ..< 8).map(Float.init), (8 ..< 16).map(Float.init)])
    }

    func testGapOver100msReanchorsRecreatesProcessorAndResetsPipeline() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer((0 ..< 1600).map(Float.init), endingAt: start + 0.1))
        reference.append(buffer((10000 ..< 11600).map(Float.init), endingAt: start + 0.6))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            calls.recordCreation()
            return FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 8.0 / 16000)) { 0 }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 0.5 + 8.0 / 16000)) { 0 }

        XCTAssertEqual(calls.creations, 2, "a gap over 0.1 s must start a fresh context")
        XCTAssertEqual(calls.references, [(0 ..< 8).map(Float.init), (10000 ..< 10008).map(Float.init)])
        let flushCount = await pipeline.flushCount
        let resetCount = await pipeline.resetCount
        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(resetCount, 1)
    }

    func testFlushPadsPartialHopButDeliversOnlyValidSamples() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        reference.append(buffer(Array(repeating: 4, count: 8), endingAt: 4))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        await canceller.ingest(buffer([1, 2, 3], endingAt: 10 + 3.0 / 16000)) { 0 }
        await canceller.flush()

        let received = await pipeline.buffers
        XCTAssertEqual(received.map(\.samples), [[11, 12, 13]])
        XCTAssertEqual(calls.microphones, [[1, 2, 3, 0, 0, 0, 0, 0]])
        XCTAssertEqual(calls.references, [Array(repeating: 0, count: 8)], "stale app audio is silence")
        let flushCount = await pipeline.flushCount
        XCTAssertEqual(flushCount, 1)
    }

    func testProcessingFailurePassesThroughRemainingRecordingWithoutLosingAudio() async {
        let calls = HopCalls(throwOnCall: 2)
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 20), endingAt: 10 + 20.0 / 16000)) { 0 }
        await canceller.ingest(buffer(Array(repeating: 2, count: 4), endingAt: 10 + 24.0 / 16000)) { 0 }
        await canceller.flush()

        let buffers = await pipeline.buffers
        let received = buffers.flatMap(\.samples)
        XCTAssertEqual(received, Array(repeating: 11, count: 8) + Array(repeating: 1, count: 12) + Array(repeating: 2, count: 4))
        XCTAssertEqual(calls.microphones.count, 2, "the failed context must not run again")
    }

    func testResetDiscardsPendingTailAndRecreatesSuccessfulProcessor() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            calls.recordCreation()
            return FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        await canceller.ingest(buffer([1, 1, 1], endingAt: 10 + 3.0 / 16000)) { 0 }
        await canceller.reset()
        await canceller.ingest(buffer(Array(repeating: 2, count: 8), endingAt: 11)) { 0 }
        await canceller.flush()

        let buffers = await pipeline.buffers
        XCTAssertEqual(buffers.flatMap(\.samples), Array(repeating: 12, count: 8))
        XCTAssertEqual(calls.creations, 2)
        XCTAssertEqual(calls.microphones, [Array(repeating: 2, count: 8)])
    }

    func testFailureRemainsPassthroughAfterFeedReset() async {
        let calls = HopCalls(throwOnCall: 1)
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: 10)) { 0 }
        await canceller.reset()
        await canceller.ingest(buffer(Array(repeating: 2, count: 8), endingAt: 11)) { 0 }
        await canceller.flush()

        let buffers = await pipeline.buffers
        let received = buffers.flatMap(\.samples)
        XCTAssertEqual(received, Array(repeating: 2, count: 8))
        XCTAssertEqual(calls.microphones.count, 1, "a feed reset must not retry a failed model in this recording")
    }

    func testUnsupportedBufferPassesThroughUnchangedWithoutInitializingOrRecreatingRepeatedly() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            calls.recordCreation()
            return FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        let unsupported = LiveAudioBuffer(samples: [3, 4], channelCount: 1, sampleRate: 48000, hostTime: 0)
        await canceller.ingest(unsupported) { 0 }
        await canceller.flush()

        let received = await pipeline.buffers
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.samples, unsupported.samples)
        XCTAssertEqual(received.first?.sampleRate, unsupported.sampleRate)
        XCTAssertEqual(calls.microphones.count, 0)
        XCTAssertEqual(calls.creations, 0, "unsupported buffers and idle flushes must not load the model")

        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: 10)) { 0 }
        await canceller.ingest(unsupported) { 0 }
        await canceller.ingest(unsupported) { 0 }
        XCTAssertEqual(calls.creations, 2, "repeated unsupported buffers must recreate the context at most once")
    }

    func testSmallPositiveHostTimeDoesNotTrap() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        await canceller.ingest(LiveAudioBuffer(samples: Array(repeating: 1, count: 8), channelCount: 1, sampleRate: 16000, hostTime: 1)) { 0 }
        await canceller.flush()

        let received = await pipeline.buffers.flatMap(\.samples)
        XCTAssertEqual(received, Array(repeating: 11, count: 8))
    }

    private func buffer(_ samples: [Float], endingAt seconds: Double) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: samples, channelCount: 1, sampleRate: 16000,
            hostTime: SampleRateDriftDetector.secondsToMachTicks(seconds),
        )
    }
}

private struct HopFailure: Error {}

private final class HopCalls: Sendable {
    private struct State {
        var microphones: [[Float]] = []
        var references: [[Float]] = []
        var creations = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let throwOnCall: Int?

    init(throwOnCall: Int? = nil) {
        self.throwOnCall = throwOnCall
    }

    var microphones: [[Float]] {
        state.withLock { $0.microphones }
    }

    var references: [[Float]] {
        state.withLock { $0.references }
    }

    var creations: Int {
        state.withLock { $0.creations }
    }

    func recordCreation() {
        state.withLock { $0.creations += 1 }
    }

    func record(mic: [Float], reference: [Float]) throws {
        let call = state.withLock { state -> Int in
            state.microphones.append(mic)
            state.references.append(reference)
            return state.microphones.count
        }
        if call == throwOnCall { throw HopFailure() }
    }
}

private final class FakeCaptionHop: LiveCaptionHopCancelling {
    let hopLength = 8
    private let calls: HopCalls
    private let output: ([Float], [Float]) -> [Float]

    init(calls: HopCalls, output: @escaping ([Float], [Float]) -> [Float]) {
        self.calls = calls
        self.output = output
    }

    func process(mic: [Float], reference: [Float]) throws -> [Float] {
        try calls.record(mic: mic, reference: reference)
        return output(mic, reference)
    }
}

private actor EchoOutputPipeline: LiveCaptionPipeline {
    private(set) var buffers: [LiveAudioBuffer] = []
    private(set) var flushCount = 0
    private(set) var resetCount = 0

    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {
        buffers.append(buffer)
    }

    func reset() {
        resetCount += 1
        buffers = []
    }

    func flush() {
        flushCount += 1
    }
}
