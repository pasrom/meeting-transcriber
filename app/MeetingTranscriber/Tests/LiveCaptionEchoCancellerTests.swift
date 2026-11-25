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

    func testHopWaitsForReferenceThatIsOnItsWay() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer(Array(repeating: 2, count: 4), endingAt: start + 4.0 / 16000))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 8.0 / 16000)) { 0 }
        XCTAssertTrue(calls.references.isEmpty, "a hop the app audio has not covered yet must wait for it")
        reference.append(buffer(Array(repeating: 3, count: 4), endingAt: start + 8.0 / 16000))
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 16.0 / 16000)) { 0 }

        XCTAssertEqual(calls.references.first, [2, 2, 2, 2, 3, 3, 3, 3])
        let zeroFilled = await canceller.zeroFilledSeconds
        XCTAssertEqual(zeroFilled, 0)
    }

    func testHopStopsWaitingForReferenceAfterBoundAndCountsZeroFill() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer(Array(repeating: 2, count: 4), endingAt: start + 4.0 / 16000))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        let waitSamples = Int(LiveCaptionEchoCanceller.referenceWait * 16000) + 16
        await canceller.ingest(buffer(Array(repeating: 1, count: 8 + waitSamples), endingAt: start + Double(8 + waitSamples) / 16000)) { 0 }

        XCTAssertEqual(calls.references.first, [2, 2, 2, 2, 0, 0, 0, 0], "app audio that never comes must not hold the mic forever")
        let zeroFilled = await canceller.zeroFilledSeconds
        XCTAssertGreaterThanOrEqual(zeroFilled, 4.0 / 16000)
    }

    func testFlushWithTwoHopsWaitingOnReferenceDeliversEachHop() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer(Array(repeating: 2, count: 8), endingAt: start + 8.0 / 16000))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        // App audio stops after the first hop, so the next two wait on it when the recording stops.
        await canceller.ingest(buffer(Array(repeating: 1, count: 24), endingAt: start + 24.0 / 16000)) { 0 }
        XCTAssertEqual(calls.microphones.count, 1)
        await canceller.flush()

        let received = await pipeline.buffers
        XCTAssertEqual(received.map(\.samples), Array(repeating: Array(repeating: 11, count: 8), count: 3))
        XCTAssertEqual(calls.microphones.count, 3)
    }

    func testBacklogPassesMicrophoneThroughThenResumesWithFreshContext() async {
        let calls = HopCalls()
        let clock = FakeClock()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference(), factory: {
            calls.recordCreation()
            return FakeCaptionHop(calls: calls) { mic, _ in
                clock.advance(0.3)
                return mic.map { $0 + 10 }
            }
        }, clock: clock.now)
        await canceller.ingest(buffer(Array(repeating: 0, count: 8), endingAt: 10 + 8.0 / 16000)) { 0 }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: 10 + 16.0 / 16000)) { 0.9 }
        await canceller.ingest(buffer(Array(repeating: 2, count: 8), endingAt: 10 + 24.0 / 16000)) { 1.1 }
        await canceller.ingest(buffer(Array(repeating: 3, count: 8), endingAt: 10 + 32.0 / 16000)) { 0.5 }
        await canceller.ingest(buffer(Array(repeating: 4, count: 8), endingAt: 10 + 40.0 / 16000)) { 0.25 }
        await canceller.flush()

        let buffers = await pipeline.buffers
        let expected = ([10, 11, 2, 3, 14] as [Float]).flatMap { Array(repeating: $0, count: 8) }
        XCTAssertEqual(
            buffers.flatMap(\.samples),
            expected,
            "a backed-up queue must bypass past bypassBacklog, stay bypassed above resumeBacklog, and resume at resumeBacklog",
        )
        XCTAssertEqual(
            buffers.map(\.hostTime),
            [8, 16, 24, 32, 40].map { SampleRateDriftDetector.secondsToMachTicks(10 + Double($0) / 16000) },
        )
        XCTAssertEqual(calls.creations, 1, "resuming resets the context instead of reloading the model")
        XCTAssertEqual(calls.resets, 1, "resuming starts from a fresh streaming state")
    }

    func testBacklogFromSlowASRKeepsCancelling() async {
        let calls = HopCalls()
        let clock = FakeClock()
        // A 0.3 s ASR stall clears BusyWindow.minimumEvidence so asrLoad.share >= 1.0 and only the ASR clause keeps cancelling.
        let pipeline = EchoOutputPipeline { clock.advance(0.3) }
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference(), factory: {
            FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }, clock: clock.now)
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: 10 + 8.0 / 16000)) { 0 }
        await canceller.ingest(buffer(Array(repeating: 2, count: 8), endingAt: 10 + 16.0 / 16000)) { 3 }
        await canceller.flush()

        let received = await pipeline.buffers.flatMap(\.samples)
        XCTAssertEqual(
            received,
            Array(repeating: 11, count: 8) + Array(repeating: 12, count: 8),
            "passing through cannot drain a queue that ASR itself fills",
        )
    }

    func testBacklogWithFastCancellerAndFastASRKeepsCancelling() async {
        let calls = HopCalls()
        let clock = FakeClock()
        let pipeline = EchoOutputPipeline { clock.advance(0.00005) }
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference(), factory: {
            FakeCaptionHop(calls: calls) { mic, _ in
                clock.advance(0.0001)
                return mic.map { $0 + 10 }
            }
        }, clock: clock.now)
        // Mirrors a held language-probe replay (initial backlog > 1 s) followed by a draining backlog.
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: 10 + 8.0 / 16000)) { 8 }
        await canceller.ingest(buffer(Array(repeating: 2, count: 8), endingAt: 10 + 16.0 / 16000)) { 3 }
        await canceller.flush()

        let received = await pipeline.buffers.flatMap(\.samples)
        XCTAssertEqual(
            received,
            Array(repeating: 11, count: 8) + Array(repeating: 12, count: 8),
            "a backlog that canceller + ASR already drain faster than real time must stay cancelled",
        )
    }

    func testMidBufferSlowHopBypassesRemainingHops() async {
        let calls = HopCalls()
        let clock = FakeClock()
        let backlog = OSAllocatedUnfairLock(initialState: 0.0)
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference(), factory: {
            FakeCaptionHop(calls: calls) { mic, _ in
                clock.advance(0.3)
                backlog.withLock { $0 = 2.0 }
                return mic.map { $0 + 10 }
            }
        }, clock: clock.now)
        let threeHops = Array(repeating: Float(1), count: 8) + Array(repeating: Float(2), count: 8) + Array(repeating: Float(3), count: 8)
        await canceller.ingest(buffer(threeHops, endingAt: 10 + 24.0 / 16000)) { backlog.withLock { $0 } }
        await canceller.flush()

        let buffers = await pipeline.buffers
        XCTAssertEqual(
            buffers.map(\.samples),
            [Array(repeating: 11, count: 8), Array(repeating: 2, count: 8) + Array(repeating: 3, count: 8)],
            "a stalled hop must bypass the rest of the same buffer without slicing it into hops",
        )
        XCTAssertEqual(calls.microphones.count, 1, "a stalled hop must bypass the rest of the same buffer")
    }

    func testOneSlowHopOfFreshContextOnReplayBacklogKeepsCancelling() async {
        let calls = HopCalls()
        let clock = FakeClock()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference(), factory: {
            FakeCaptionHop(calls: calls) { mic, _ in
                // The first hop of a cold context runs slower than real time; later hops do not.
                clock.advance(calls.microphones.count == 1 ? 0.002 : 0)
                return mic.map { $0 + 10 }
            }
        }, clock: clock.now)
        let twoHops = Array(repeating: Float(1), count: 8) + Array(repeating: Float(2), count: 8)
        // An auto-detect replay starts with more than a second queued.
        await canceller.ingest(buffer(twoHops, endingAt: 10 + 16.0 / 16000)) { 2 }
        await canceller.flush()

        let received = await pipeline.buffers.flatMap(\.samples)
        XCTAssertEqual(received, Array(repeating: 11, count: 8) + Array(repeating: 12, count: 8), "one slow hop is not a trend")
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

    func testResetDiscardsPendingTailAndResetsContext() async {
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
        XCTAssertEqual(calls.creations, 1)
        XCTAssertEqual(calls.resets, 1)
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

    func testUnsupportedBufferPassesThroughUnchangedWithoutInitializingOrResettingRepeatedly() async {
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
        XCTAssertEqual(calls.creations, 1)
        XCTAssertEqual(calls.resets, 1, "repeated unsupported buffers must reset the context at most once")
    }

    func testFlushFreesContextAndLaterAudioPassesThrough() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            FakeCaptionHop(calls: calls) { mic, _ in mic.map { $0 + 10 } }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: 10)) { 0 }
        let before = await canceller.isCancelling
        await canceller.flush()
        let after = await canceller.isCancelling
        await canceller.ingest(buffer(Array(repeating: 2, count: 8), endingAt: 11)) { 0 }

        XCTAssertTrue(before)
        XCTAssertFalse(after, "the stop flush must release the context")
        XCTAssertEqual(calls.microphones.count, 1)
    }

    func testUnavailableModelPassesMicrophoneThroughUnchanged() async {
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) { nil }
        await canceller.ingest(buffer([1, 2, 3], endingAt: 10)) { 0 }
        await canceller.flush()

        let received = await pipeline.buffers.flatMap(\.samples)
        XCTAssertEqual(received, [1, 2, 3])
        let cancelling = await canceller.isCancelling
        XCTAssertFalse(cancelling)
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

struct HopFailure: Error {}

final class HopCalls: Sendable {
    private struct State {
        var microphones: [[Float]] = []
        var references: [[Float]] = []
        var creations = 0
        var resets = 0
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

    var resets: Int {
        state.withLock { $0.resets }
    }

    func recordReset() {
        state.withLock { $0.resets += 1 }
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

final class FakeCaptionHop: LiveCaptionHopCancelling {
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

    func reset() {
        calls.recordReset()
    }
}

final class FakeClock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: 0.0)
    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 += seconds }
    }

    @Sendable
    func now() -> TimeInterval {
        time.withLock { $0 }
    }
}

actor EchoOutputPipeline: LiveCaptionPipeline {
    private(set) var buffers: [LiveAudioBuffer] = []
    private(set) var flushCount = 0
    private(set) var resetCount = 0
    private let onIngest: @Sendable () -> Void

    init(onIngest: @escaping @Sendable () -> Void = {}) {
        self.onIngest = onIngest
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {
        onIngest()
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
