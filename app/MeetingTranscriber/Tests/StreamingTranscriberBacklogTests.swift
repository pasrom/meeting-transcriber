import AudioTapLib
import Foundation
@testable import MeetingTranscriber
import XCTest

final class StreamingTranscriberBacklogTests: XCTestCase {
    func testBacklogSkipsPartialsButSpeechEndStillTranscribes() async {
        let detector = ScriptedBoundaryDetector([.speechStart, nil, nil, nil, .speechEnd])
        let recorder = CaptionTranscriptionRecorder()
        let transcriber = makeTranscriber(detector: detector, recorder: recorder)

        for _ in 0 ..< 5 {
            await transcriber.ingest(chunk()) { 1.0 }
        }

        XCTAssertTrue(recorder.partials.isEmpty)
        XCTAssertEqual(recorder.transcribedSampleCounts, [16384])
        XCTAssertEqual(recorder.finalSampleCounts, [16384])
    }

    func testPartialResumesWhenBacklogDrainsAndFlushStillTranscribes() async {
        let detector = ScriptedBoundaryDetector([.speechStart, nil, nil, nil, nil])
        let recorder = CaptionTranscriptionRecorder()
        let transcriber = makeTranscriber(detector: detector, recorder: recorder)

        await transcriber.ingest(chunk()) { 1.0 }
        await transcriber.ingest(chunk()) { 1.0 }
        XCTAssertTrue(recorder.transcribedSampleCounts.isEmpty)

        await transcriber.ingest(chunk()) { 0.0 }
        await transcriber.ingest(chunk()) { 0.0 }
        // The 0.8 s wall-clock lastPartialAt guard suppresses further partials during these calls.
        XCTAssertEqual(recorder.partials, ["words"])

        await transcriber.ingest(chunk()) { 1.0 }
        await transcriber.flush()
        XCTAssertEqual(recorder.finalSampleCounts, [20480])
    }

    func testUndrainedSamplesInsideOneBufferDelayPartial() async {
        let detector = ScriptedBoundaryDetector([.speechStart] + Array(repeating: nil, count: 7))
        let recorder = CaptionTranscriptionRecorder()
        let transcriber = makeTranscriber(detector: detector, recorder: recorder)
        let large = LiveAudioBuffer(
            samples: [Float](repeating: 0, count: 8 * 4096),
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 0,
        )

        await transcriber.ingest(large) { 0 }

        // The 0.8 s wall-clock lastPartialAt guard suppresses further partials while this buffer drains.
        XCTAssertEqual(recorder.partials, ["words"])
        XCTAssertGreaterThanOrEqual(recorder.transcribedSampleCounts.first ?? 0, 5 * 4096)
    }

    func testBacklogNeverSuppressesFiveSecondFinal() async {
        let detector = ScriptedBoundaryDetector([.speechStart] + Array(repeating: nil, count: 19))
        let recorder = CaptionTranscriptionRecorder()
        let transcriber = makeTranscriber(detector: detector, recorder: recorder)

        for _ in 0 ..< 20 {
            await transcriber.ingest(chunk()) { 1.0 }
        }

        XCTAssertTrue(recorder.partials.isEmpty)
        XCTAssertEqual(recorder.finalSampleCounts, [81920])
    }

    func testDiscontinuityDiscardsPendingSpeechBeforeNextFinal() async {
        let detector = ScriptedBoundaryDetector(
            [.speechStart, nil, nil, nil, .speechStart, nil, nil, nil],
        )
        let recorder = CaptionTranscriptionRecorder()
        let transcriber = makeTranscriber(detector: detector, recorder: recorder)

        for _ in 0 ..< 4 {
            await transcriber.ingest(chunk()) { 1.0 }
        }
        await transcriber.ingest(chunk(sampleCount: 1024)) { 1.0 }
        await transcriber.reset()
        let resetCount = await detector.resetCount
        XCTAssertEqual(resetCount, 1)
        for _ in 0 ..< 4 {
            await transcriber.ingest(chunk(value: 2)) { 1.0 }
        }
        await transcriber.flush()

        XCTAssertEqual(recorder.finalSampleCounts, [16384])
        XCTAssertEqual(Set(recorder.finalAudio), [2])
        XCTAssertEqual(recorder.partials, [""])
    }

    func testTransientDetectorFailureRetriesTheSameAudio() async {
        let detector = ScriptedBoundaryDetector([.speechStart, nil, nil, nil, nil])
        await detector.failOnce()
        let recorder = CaptionTranscriptionRecorder()
        let transcriber = makeTranscriber(detector: detector, recorder: recorder)

        await transcriber.ingest(chunk(sampleCount: 4 * 4096)) { 1.0 }
        await transcriber.ingest(chunk()) { 1.0 }
        await transcriber.flush()

        XCTAssertEqual(recorder.finalSampleCounts, [5 * 4096])
    }

    func testPersistentDetectorFailureDropsChunksAndLaterSpeechTranscribes() async {
        let detector = ScriptedBoundaryDetector([.speechStart, nil, nil, nil])
        await detector.setFailing(true)
        let recorder = CaptionTranscriptionRecorder()
        let transcriber = makeTranscriber(detector: detector, recorder: recorder)

        for _ in 0 ..< 8 {
            await transcriber.ingest(chunk(value: 1)) { 1.0 }
        }
        let failedCalls = await detector.boundaryCallCount
        XCTAssertEqual(failedCalls, 8 * 3)

        await detector.setFailing(false)
        for _ in 0 ..< 4 {
            await transcriber.ingest(chunk(value: 2)) { 1.0 }
        }
        await transcriber.flush()

        XCTAssertEqual(recorder.finalSampleCounts, [4 * 4096])
        XCTAssertEqual(Set(recorder.finalAudio), [2])
    }

    private func makeTranscriber(
        detector: ScriptedBoundaryDetector,
        recorder: CaptionTranscriptionRecorder,
    ) -> StreamingTranscriber {
        StreamingTranscriber(
            channelLabel: "test",
            detector: detector,
            transcribe: { samples in
                recorder.recordTranscription(samples.count)
                return "words"
            },
            onEvent: { recorder.record($0) },
        )
    }

    private func chunk(sampleCount: Int = 4096, value: Float = 0) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: [Float](repeating: value, count: sampleCount),
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 0,
        )
    }
}

private actor ScriptedBoundaryDetector: UtteranceBoundaryDetecting {
    enum Failure: Error { case temporary }

    private var events: [FluidVAD.StreamEvent.Kind?]
    private(set) var resetCount = 0
    private(set) var boundaryCallCount = 0
    private var failNext = false
    private var isFailing = false

    init(_ events: [FluidVAD.StreamEvent.Kind?]) {
        self.events = events
    }

    func failOnce() {
        failNext = true
    }

    func setFailing(_ value: Bool) {
        isFailing = value
    }

    func boundary(in _: [Float]) throws -> FluidVAD.StreamEvent.Kind? {
        boundaryCallCount += 1
        if failNext || isFailing {
            failNext = false
            throw Failure.temporary
        }
        return events.isEmpty ? nil : events.removeFirst()
    }

    func reset() {
        resetCount += 1
    }
}

private final class CaptionTranscriptionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _transcribedSampleCounts: [Int] = []
    private var _partialTexts: [String] = []
    private var _finalSampleCounts: [Int] = []

    var transcribedSampleCounts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _transcribedSampleCounts
    }

    var partials: [String] {
        lock.lock(); defer { lock.unlock() }
        return _partialTexts
    }

    var finalSampleCounts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _finalSampleCounts
    }

    var finalAudio: [Float] {
        lock.lock(); defer { lock.unlock() }
        return _finalAudio
    }

    private var _finalAudio: [Float] = []

    func recordTranscription(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        _transcribedSampleCounts.append(count)
    }

    func record(_ event: StreamingTranscriber.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .partial(text):
            _partialTexts.append(text)

        case let .finalized(_, audio):
            _finalSampleCounts.append(audio.count)
            _finalAudio = audio
        }
    }
}
