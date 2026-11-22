import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Mic and reference placement on the sample-count timeline, and the context resets it triggers.
@MainActor
final class LiveCaptionEchoAlignmentTests: XCTestCase {
    func testLateCallbackStampDoesNotShiftReferenceAlignment() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        reference.append(buffer((0 ..< 8).map(Float.init), endingAt: start + 8.0 / 16000))
        // App callback forwarded 150 ms late: its stamp is not when the audio was captured.
        reference.append(buffer((8 ..< 16).map(Float.init), endingAt: start + 16.0 / 16000 + 0.15))
        reference.append(buffer((16 ..< 24).map(Float.init), endingAt: start + 24.0 / 16000))
        await canceller.ingest(buffer(Array(repeating: 1, count: 24), endingAt: start + 24.0 / 16000)) { 0 }

        XCTAssertEqual(calls.references, [0 ..< 8, 8 ..< 16, 16 ..< 24].map { $0.map(Float.init) })
    }

    func testLateMicStampOver100msKeepsTimelineContextAndCaptionLine() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer((0 ..< 1600).map(Float.init), endingAt: start + 0.1))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 8.0 / 16000)) { 0 }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 16.0 / 16000 + 0.15)) { 0 }
        await canceller.ingest(buffer(Array(repeating: 1, count: 8), endingAt: start + 24.0 / 16000)) { 0 }

        XCTAssertEqual(calls.references, [0 ..< 8, 8 ..< 16, 16 ..< 24].map { $0.map(Float.init) })
        XCTAssertEqual(calls.resets, 0, "one late stamp is jitter, not a gap")
        let flushCount = await pipeline.flushCount
        XCTAssertEqual(flushCount, 0, "a late stamp must not cut the caption line")
    }

    func testBurstOfMicBuffersStampedTogetherKeepsTimeline() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: 10.05)) { 0 }
        // The capture queue stalled for 0.5 s, then delivered ten 50 ms buffers with nearly one stamp.
        for _ in 0 ..< 10 {
            await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: 10.6)) { 0 }
        }
        let received = await pipeline.buffers

        XCTAssertEqual(calls.resets, 0, "a burst after a stall lost no audio")
        XCTAssertEqual(received.last.map { SampleRateDriftDetector.machTicksToSeconds($0.hostTime) } ?? 0, 10.55, accuracy: 1e-6)
    }

    func testGapConfirmedOver200msReanchorsResetsContextAndPipeline() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            calls.recordCreation()
            return FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: 10.05)) { 0 }
        // 0.5 s of mic audio lost, then buffers on time again.
        for index in 1 ... 5 {
            await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: 10.55 + 0.05 * Double(index))) { 0 }
        }
        let flushCount = await pipeline.flushCount
        let resetCount = await pipeline.resetCount
        let received = await pipeline.buffers

        XCTAssertEqual(calls.creations, 1, "a re-anchor resets the context instead of reloading the model")
        XCTAssertEqual(calls.resets, 1)
        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(received.last.map { SampleRateDriftDetector.machTicksToSeconds($0.hostTime) } ?? 0, 10.8, accuracy: 1e-6)
    }

    func testBackwardDriftRealignsContextWithoutCuttingCaptionLine() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: LiveCaptionEchoReference()) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: 10.05)) { 0 }
        // The mic clock ran fast: its samples now reach 150 ms past host time.
        for index in 1 ... 5 {
            await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: 9.9 + 0.05 * Double(index))) { 0 }
        }
        let flushCount = await pipeline.flushCount
        let resetCount = await pipeline.resetCount

        XCTAssertEqual(calls.resets, 1, "a moved timeline needs a fresh streaming state")
        XCTAssertEqual(flushCount, 0, "no audio was lost, so the caption line goes on")
        XCTAssertEqual(resetCount, 0)
    }

    func testLateMicAnchorRealignsPendingAudioAndResetsContextOnce() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        // Sample n of the app audio holds the value n, so a reference names its own position.
        reference.append(buffer((0 ..< 24000).map(Float.init), endingAt: start + 1.5))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        // 805-sample buffers leave mic samples pending when the correction lands; the first stamp is 50 ms late.
        let count = 805
        for index in 0 ..< 22 {
            let late = index == 0 ? 0.05 : 0
            let end = start + Double(count * (index + 1)) / 16000 + late
            await canceller.ingest(buffer(Array(repeating: 1, count: count), endingAt: end)) { 0 }
        }

        let lastHop = calls.references.count - 1
        XCTAssertEqual(calls.references.last, (lastHop * 8 ..< lastHop * 8 + 8).map(Float.init), "mic hops must meet the app audio of their own time")
        XCTAssertEqual(calls.resets, 1, "a 50 ms correction is beyond what LocalVQE holds mid-context")
    }

    func testReferenceMoveResetsCancellerContext() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        // The first app buffer was forwarded 50 ms late, so the reference realigns after a second.
        for index in 0 ..< 22 {
            let end = start + 0.05 * Double(index + 1)
            reference.append(buffer(Array(repeating: 0, count: 800), endingAt: end + (index == 0 ? 0.05 : 0)))
            await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: end)) { 0 }
        }

        XCTAssertEqual(referenceMoves(reference), 1)
        XCTAssertEqual(calls.resets, 1, "a moved reference shifts the lag LocalVQE converged on")
    }

    func testReferenceForwardMoveCarriesConfirmingBuffers() {
        let reference = LiveCaptionEchoReference()
        reference.append(buffer(Array(repeating: 9, count: 800), endingAt: 10.05))
        // 0.5 s of app audio lost; four on-time buffers confirm the gap.
        for index in 1 ... 4 {
            reference.append(buffer(Array(repeating: Float(index), count: 800), endingAt: 10.55 + 0.05 * Double(index)))
        }

        let gap = reference.samples(from: 10.05, count: 800)
        XCTAssertEqual(gap.moves, 1)
        XCTAssertEqual(gap.missing, 800, "the gap holds no app audio")
        for index in 1 ... 4 {
            XCTAssertEqual(
                reference.samples(from: 10.5 + 0.05 * Double(index), count: 800).samples,
                Array(repeating: Float(index), count: 800),
                "buffer \(index) must sit after the gap",
            )
        }
    }

    func testReferenceBackwardMoveTrimsOverlappedAudio() {
        let reference = LiveCaptionEchoReference()
        reference.append(buffer(Array(repeating: 9, count: 4800), endingAt: 10.3))
        // The output clock ran fast: the next buffers are stamped 150 ms before the sample count.
        for index in 1 ... 4 {
            reference.append(buffer(Array(repeating: Float(index), count: 800), endingAt: 10.15 + 0.05 * Double(index)))
        }

        let expected = Array(repeating: Float(9), count: 2400) + [1, 2, 3].flatMap { Array(repeating: Float($0), count: 800) }
        let read = reference.samples(from: 10.0, count: 4800)
        XCTAssertEqual(read.moves, 1)
        XCTAssertEqual(read.samples, expected)
        XCTAssertEqual(reference.samples(from: 10.0, count: 6400).missing, 800, "overlapped audio must not count as covering twice")
    }

    func testReferenceLateAnchorRealignsRetainedAudio() {
        let reference = LiveCaptionEchoReference()
        for index in 0 ..< 22 {
            let end = 10 + 0.05 * Double(index + 1) + (index == 0 ? 0.05 : 0)
            reference.append(buffer(Array(repeating: Float(index + 1), count: 800), endingAt: end))
        }

        XCTAssertEqual(reference.samples(from: 10.0, count: 800).samples, Array(repeating: 1, count: 800))
        XCTAssertEqual(reference.samples(from: 10.5, count: 800).samples, Array(repeating: 11, count: 800))
        XCTAssertEqual(reference.samples(from: 11.05, count: 800).samples, Array(repeating: 22, count: 800))
    }

    func testSmallMicRealignmentWithinContextLimitKeepsContext() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        reference.append(buffer((0 ..< 24000).map(Float.init), endingAt: start + 1.5))
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        // 6 ms is above realignSlack (4 ms) and within contextShiftLimit (8 ms).
        let count = 805
        for index in 0 ..< 22 {
            let late = index == 0 ? 0.006 : 0
            let end = start + Double(count * (index + 1)) / 16000 + late
            await canceller.ingest(buffer(Array(repeating: 1, count: count), endingAt: end)) { 0 }
        }

        let lastHop = calls.references.count - 1
        XCTAssertEqual(calls.references.last, (lastHop * 8 ..< lastHop * 8 + 8).map(Float.init))
        XCTAssertEqual(calls.resets, 0, "a realignment within the 8 ms limit must keep the streaming context")
    }

    func testSmallReferenceRealignmentWithinContextLimitKeepsContext() async {
        let calls = HopCalls()
        let pipeline = EchoOutputPipeline()
        let reference = LiveCaptionEchoReference()
        let start = 10.0
        let canceller = LiveCaptionEchoCanceller(pipeline: pipeline, reference: reference) {
            FakeCaptionHop(calls: calls) { mic, _ in mic }
        }
        for index in 0 ..< 22 {
            let end = start + 0.05 * Double(index + 1)
            reference.append(buffer(Array(repeating: Float(index + 1), count: 800), endingAt: end + (index == 0 ? 0.006 : 0)))
            await canceller.ingest(buffer(Array(repeating: 1, count: 800), endingAt: end)) { 0 }
        }

        let read = reference.samples(from: 10.0, count: 800)
        XCTAssertEqual(read.samples, Array(repeating: 1, count: 800))
        XCTAssertEqual(read.moves, 0, "a reference realignment within 8 ms must not count as a context-resetting move")
        XCTAssertEqual(calls.resets, 0)
    }

    func testUnsupportedAppAudioAfterAnchorCountsAsReferenceMove() {
        let reference = LiveCaptionEchoReference()
        let unsupported = LiveAudioBuffer(samples: [1, 2], channelCount: 1, sampleRate: 48000, hostTime: 1000)
        reference.append(unsupported)
        XCTAssertEqual(referenceMoves(reference), 0, "unsupported audio before anchoring did not move a timeline")

        reference.append(buffer(Array(repeating: 1, count: 800), endingAt: 10.05))
        reference.append(unsupported)
        reference.append(unsupported)
        XCTAssertEqual(referenceMoves(reference), 1, "clearing an anchored reference timeline must signal a move once")
    }

    private func referenceMoves(_ reference: LiveCaptionEchoReference) -> Int {
        reference.samples(from: 0, count: 0).moves
    }

    private func buffer(_ samples: [Float], endingAt seconds: Double) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: samples, channelCount: 1, sampleRate: 16000,
            hostTime: SampleRateDriftDetector.secondsToMachTicks(seconds),
        )
    }
}
