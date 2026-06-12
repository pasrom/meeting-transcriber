import AudioTapLib
@preconcurrency import AVFoundation
import Foundation
@testable import MeetingTranscriber
import XCTest

/// Unit coverage for `EouStreamingCaptionSession` — the streaming-EOU strategy
/// behind the `LiveCaptionPipeline` seam. Everything here runs against
/// `MockEouStreamingAsrManaging` (no CoreML, no real audio), so the suite is
/// fully deterministic: the mock fires its scripted partial/EOU callbacks
/// synchronously during `processBufferedAudio()`, mirroring how the real
/// `StreamingEouAsrManager` invokes them on its executor while decoding.
///
/// The ring buffer is filled with recognizable ramps (sample value == its
/// absolute index) so audio-slice assertions can check exact VALUES, not just
/// counts — proving the session maps the manager's millisecond timestamps onto
/// the right sample window.
final class EouStreamingCaptionSessionTests: XCTestCase {
    // MARK: - Test doubles

    /// One scripted callback the mock fires during a `processBufferedAudio()`
    /// pass. `.partial` → partialCallback, `.eou` → eouCallback.
    private enum ScriptedCallback {
        case partial(String)
        case eou(String)
    }

    /// Mock conforming to the narrow `EouStreamingAsrManaging` seam. Records the
    /// frame counts + formats of every `appendAudio` buffer, counts `reset()`
    /// and `finish()` calls, returns a scripted `finish()` string, and — per
    /// `processBufferedAudio()` call — fires a scripted callback sequence
    /// synchronously (exactly as the real manager does while decoding a chunk).
    private actor MockEouStreamingAsrManaging: EouStreamingAsrManaging {
        // Recorded inputs.
        private(set) var appendedFrameLengths: [Int] = []
        private(set) var appendedFormats: [(sampleRate: Double, channels: AVAudioChannelCount, isFloat: Bool)] = []
        private(set) var resetCount = 0
        private(set) var finishCount = 0
        private(set) var loadModelsCount = 0

        // Scripted outputs.
        /// Callback batches, one per `processBufferedAudio()` call (FIFO).
        private var scriptedBatches: [[ScriptedCallback]] = []
        /// EOU timestamps the session reads via `getEouTimestampsMs().last`.
        private var eouTimestampsMs: [Int] = []
        /// Value `finish()` returns (the destructive trailing transcript).
        private var finishReturn = ""
        /// Error thrown by `loadModels()` (for the prepare()-rethrows test).
        private var loadModelsError: (any Error)?
        /// When true, each `processBufferedAudio()` call fires ONE EOU whose
        /// transcript is the accumulated word list `w0 w1 … wK` (K = call index)
        /// and whose timestamp grows by `autoEouStepMs`. Because the manager's
        /// transcript grows across utterances, the session must prefix-strip each
        /// EOU against the previous one to recover the single new word — pinning
        /// that prefix + cursor advance stay in lockstep across utterances.
        private var autoEou = false
        private var autoEouWords: [String] = []
        private var autoEouStepMs = 0
        private var autoEouCallCount = 0

        private var partialCallback: (@Sendable (String) -> Void)?
        private var eouCallback: (@Sendable (String) -> Void)?

        // Scripting helpers (called before exercising the session).
        func enqueueBatch(_ batch: [ScriptedCallback]) {
            scriptedBatches.append(batch)
        }

        func setEouTimestampsMs(_ values: [Int]) {
            eouTimestampsMs = values
        }

        func setFinishReturn(_ value: String) {
            finishReturn = value
        }

        func setLoadModelsError(_ error: any Error) {
            loadModelsError = error
        }

        func enableAutoEou(words: [String], stepMs: Int) {
            autoEou = true
            autoEouWords = words
            autoEouStepMs = stepMs
        }

        // MARK: EouStreamingAsrManaging

        func loadModels() throws {
            loadModelsCount += 1
            if let loadModelsError { throw loadModelsError }
        }

        func appendAudio(_ buffer: AVAudioPCMBuffer) {
            // The session constructs a fresh buffer per call and sends it across
            // the isolation boundary, so by the time we read it here we own it.
            let format = buffer.format
            appendedFrameLengths.append(Int(buffer.frameLength))
            appendedFormats.append((
                format.sampleRate,
                format.channelCount,
                format.commonFormat == .pcmFormatFloat32,
            ))
        }

        func processBufferedAudio() {
            if autoEou, autoEouCallCount < autoEouWords.count {
                // Build the accumulated transcript w0..wK and the matching growing
                // EOU timestamp, mirroring the real manager (which appends the EOU
                // ms and fires the callback together).
                let k = autoEouCallCount
                autoEouCallCount += 1
                let transcript = autoEouWords[0 ... k].joined(separator: " ")
                eouTimestampsMs.append((k + 1) * autoEouStepMs)
                eouCallback?(transcript)
                return
            }

            guard !scriptedBatches.isEmpty else { return }
            let batch = scriptedBatches.removeFirst()
            for callback in batch {
                switch callback {
                case let .partial(text): partialCallback?(text)
                case let .eou(text): eouCallback?(text)
                }
            }
        }

        func finish() -> String {
            finishCount += 1
            return finishReturn
        }

        func reset() {
            resetCount += 1
        }

        func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) {
            partialCallback = callback
        }

        func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) {
            eouCallback = callback
        }

        func getEouTimestampsMs() -> [Int] {
            eouTimestampsMs
        }
    }

    /// Sendable, lock-protected recorder for the session's `@Sendable` event sink.
    private final class EventRecorder: @unchecked Sendable {
        struct Partial { let text: String }
        struct Final {
            let text: String
            let audio: [Float]
        }

        private let lock = NSLock()
        private var _partials: [Partial] = []
        private var _finals: [Final] = []

        var partials: [Partial] {
            lock.lock(); defer { lock.unlock() }
            return _partials
        }

        var finals: [Final] {
            lock.lock(); defer { lock.unlock() }
            return _finals
        }

        func record(_ event: StreamingTranscriber.Event) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case let .partial(text): _partials.append(Partial(text: text))
            case let .finalized(text, audio): _finals.append(Final(text: text, audio: audio))
            }
        }
    }

    // MARK: - Helpers

    /// A 16 kHz mono buffer whose samples are a ramp `[base, base+count)` so a
    /// later slice can be checked by VALUE.
    private func rampBuffer(base: Int, count: Int) -> LiveAudioBuffer {
        let samples = (base ..< base + count).map { Float($0) }
        return LiveAudioBuffer(samples: samples, channelCount: 1, sampleRate: 16000, hostTime: 0)
    }

    private func makeSession(
        asr: MockEouStreamingAsrManaging,
        recorder: EventRecorder,
    ) -> EouStreamingCaptionSession {
        EouStreamingCaptionSession(asr: asr, channelLabel: "test") { event in
            recorder.record(event)
        }
    }

    // MARK: - 1. Partial flow

    func testPartialsAreEmittedAsDeltas() async {
        let asr = MockEouStreamingAsrManaging()
        await asr.enqueueBatch([.partial("hello"), .partial("hello world")])
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        await session.ingest(rampBuffer(base: 0, count: 1600))

        XCTAssertEqual(recorder.partials.map(\.text), ["hello", "hello world"])
        XCTAssertTrue(recorder.finals.isEmpty)
    }

    // MARK: - 2. EOU finalizes with correctly sliced audio

    func testEouFinalizesWithSlicedAudioValues() async {
        let asr = MockEouStreamingAsrManaging()
        // EOU at 50 ms == sample index 800 (16 samples/ms). Slice is [0, 800).
        await asr.setEouTimestampsMs([50])
        await asr.enqueueBatch([.partial("hello"), .eou("hello world")])
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        // Ramp [0, 1600): sample value == absolute index.
        await session.ingest(rampBuffer(base: 0, count: 1600))

        XCTAssertEqual(recorder.finals.count, 1)
        XCTAssertEqual(recorder.finals.first?.text, "hello world")
        let expected = (0 ..< 800).map { Float($0) }
        XCTAssertEqual(recorder.finals.first?.audio, expected)
    }

    // MARK: - 3. Cross-utterance prefix stripping

    func testCrossUtterancePrefixStripping() async {
        let asr = MockEouStreamingAsrManaging()
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        // First utterance: EOU at 50 ms (index 800).
        await asr.setEouTimestampsMs([50])
        await asr.enqueueBatch([.eou("hello world")])
        await session.ingest(rampBuffer(base: 0, count: 800))

        // Second pass: a partial that EXTENDS the accumulated transcript, then
        // EOU at 100 ms (index 1600). The manager's transcript keeps growing, so
        // the session must strip the "hello world" prefix from both.
        await asr.setEouTimestampsMs([50, 100])
        await asr.enqueueBatch([.partial("hello world how"), .eou("hello world how are you")])
        await session.ingest(rampBuffer(base: 800, count: 800))

        XCTAssertEqual(recorder.partials.map(\.text), ["how"], "partial must not re-emit finalized prefix")
        XCTAssertEqual(recorder.finals.count, 2)
        XCTAssertEqual(recorder.finals[0].text, "hello world")
        XCTAssertEqual(recorder.finals[1].text, "how are you")
        // Second final slices [firstEouMs, secondEouMs) == [800, 1600).
        let expectedSecond = (800 ..< 1600).map { Float($0) }
        XCTAssertEqual(recorder.finals[1].audio, expectedSecond)
    }

    // MARK: - 4. Empty delta emits nothing

    func testEmptyDeltaEmitsNothing() async {
        let asr = MockEouStreamingAsrManaging()
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        // First EOU establishes the prefix.
        await asr.setEouTimestampsMs([50])
        await asr.enqueueBatch([.eou("hello world")])
        await session.ingest(rampBuffer(base: 0, count: 800))
        XCTAssertEqual(recorder.finals.count, 1)

        // Second EOU repeats the exact same transcript → delta is empty → no event.
        await asr.setEouTimestampsMs([50, 100])
        await asr.enqueueBatch([.eou("hello world")])
        await session.ingest(rampBuffer(base: 800, count: 800))

        XCTAssertEqual(recorder.finals.count, 1, "EOU whose transcript == prefix must not finalize")
        XCTAssertTrue(recorder.partials.isEmpty)
    }

    // MARK: - 5. flush commits the trailing transcript via finish()

    func testFlushCommitsTrailingTranscriptAndResetsState() async {
        let asr = MockEouStreamingAsrManaging()
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        // One EOU at 50 ms (index 800), then keep ingesting past it with no
        // further EOU — the tail lives only in finish()'s return value.
        await asr.setEouTimestampsMs([50])
        await asr.enqueueBatch([.eou("hello world")])
        await session.ingest(rampBuffer(base: 0, count: 800))
        // 50 more ms of audio with no callbacks (index 800..1600).
        await asr.enqueueBatch([])
        await session.ingest(rampBuffer(base: 800, count: 800))

        await asr.setFinishReturn("hello world goodbye")
        await session.flush()

        XCTAssertEqual(recorder.finals.count, 2)
        XCTAssertEqual(recorder.finals[1].text, "goodbye", "flush emits the finish() delta beyond the prefix")
        // Tail slice is [lastEouMs(50ms→800), ingestedEnd(1600)).
        let expectedTail = (800 ..< 1600).map { Float($0) }
        XCTAssertEqual(recorder.finals[1].audio, expectedTail)
        let resetCount = await asr.resetCount
        XCTAssertEqual(resetCount, 1, "flush must reset the manager")

        // State reset: a fresh ingest must behave like a new session (timestamps
        // from 0). EOU at 25 ms (index 400) slices [0, 400) of the NEW ramp.
        await asr.setEouTimestampsMs([25])
        await asr.enqueueBatch([.eou("fresh")])
        await session.ingest(rampBuffer(base: 5000, count: 800))

        XCTAssertEqual(recorder.finals.count, 3)
        XCTAssertEqual(recorder.finals[2].text, "fresh", "prefix must be reset after flush")
        let expectedFresh = (5000 ..< 5400).map { Float($0) }
        XCTAssertEqual(recorder.finals[2].audio, expectedFresh, "ring + ms timeline must restart at 0 after flush")
    }

    // MARK: - 6. flush idempotence

    func testFlushIsIdempotent() async {
        let asr = MockEouStreamingAsrManaging()
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        await asr.enqueueBatch([])
        await session.ingest(rampBuffer(base: 0, count: 1600))
        await asr.setFinishReturn("only utterance")

        await session.flush()
        XCTAssertEqual(recorder.finals.count, 1)
        let firstFinishCount = await asr.finishCount
        XCTAssertEqual(firstFinishCount, 1)

        await session.flush()
        XCTAssertEqual(recorder.finals.count, 1, "second flush must emit nothing")
        let secondFinishCount = await asr.finishCount
        XCTAssertEqual(secondFinishCount, 1, "second flush must not call finish() again")
    }

    func testFlushBeforeAnyIngestIsNoOp() async {
        let asr = MockEouStreamingAsrManaging()
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        await session.flush()

        XCTAssertTrue(recorder.finals.isEmpty)
        XCTAssertTrue(recorder.partials.isEmpty)
        let finishCount = await asr.finishCount
        XCTAssertEqual(finishCount, 0, "flush with nothing ingested must not call finish()")
    }

    // MARK: - 7. ingest guard

    func testIngestDropsNon16kMonoBuffers() async {
        let asr = MockEouStreamingAsrManaging()
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        let stereo = LiveAudioBuffer(samples: [0, 0, 0, 0], channelCount: 2, sampleRate: 16000, hostTime: 0)
        let highRate = LiveAudioBuffer(samples: [0, 0], channelCount: 1, sampleRate: 48000, hostTime: 0)
        await session.ingest(stereo)
        await session.ingest(highRate)

        let appended = await asr.appendedFrameLengths
        XCTAssertTrue(appended.isEmpty, "non-16k-mono buffers must never reach the manager")
        XCTAssertTrue(recorder.finals.isEmpty)
        XCTAssertTrue(recorder.partials.isEmpty)
    }

    // MARK: - 8. AVAudioPCMBuffer bridge

    func testAppendAudioBridgeFormatAndFrameLength() async {
        let asr = MockEouStreamingAsrManaging()
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        await asr.enqueueBatch([])
        await session.ingest(rampBuffer(base: 0, count: 1234))

        let frameLengths = await asr.appendedFrameLengths
        let formats = await asr.appendedFormats
        XCTAssertEqual(frameLengths, [1234], "bridged buffer frameLength must equal ingested sample count")
        XCTAssertEqual(formats.count, 1)
        XCTAssertEqual(formats.first?.sampleRate, 16000)
        XCTAssertEqual(formats.first?.channels, 1)
        XCTAssertEqual(formats.first?.isFloat, true, "bridged buffer must be Float32")
    }

    // MARK: - 9. prepare() rethrows loadModels error

    func testPrepareRethrowsLoadModelsError() async throws {
        struct LoadFailure: Error {}
        let asr = MockEouStreamingAsrManaging()
        await asr.setLoadModelsError(LoadFailure())
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        do {
            try await session.prepare()
            XCTFail("prepare() must rethrow loadModels() errors")
        } catch is LoadFailure {
            // expected
        }
        let loadCount = await asr.loadModelsCount
        XCTAssertEqual(loadCount, 1)
    }

    // MARK: - Sequential multi-EOU integrity

    /// Sequential ingest of N ramp blocks, one auto-EOU per process call —
    /// the session must emit exactly the words `w0 … w(N-1)` in order, each
    /// carrying its contiguous `[k*1600, (k+1)*1600)` ring slice. Pins that
    /// prefix stripping and the `lastEouMs` cursor advance in lockstep across
    /// many utterances. (The driver serializes `ingest` calls by contract —
    /// see `LiveCaptionPipeline` — ordering under rapid sink delivery is
    /// pinned at that boundary by `LiveCaptionFeedTests`.)
    func testSequentialMultiEouAdvancesPrefixAndCursorInLockstep() async {
        let utterances = 32
        let segment = 1600 // 100 ms at 16 kHz; matches the 100 ms EOU step.
        let words = (0 ..< utterances).map { "w\($0)" }
        let asr = MockEouStreamingAsrManaging()
        await asr.enableAutoEou(words: words, stepMs: segment / Self.samplesPerMs)
        let recorder = EventRecorder()
        let session = makeSession(asr: asr, recorder: recorder)

        for i in 0 ..< utterances {
            await session.ingest(rampBuffer(base: i * segment, count: segment))
        }

        let finals = recorder.finals
        XCTAssertEqual(finals.map(\.text), words, "EOU finals must be the words in order, one per utterance")
        for (k, final) in finals.enumerated() {
            let expected = (k * segment ..< (k + 1) * segment).map { Float($0) }
            XCTAssertEqual(final.audio, expected, "the k-th EOU must slice exactly the k-th ring block")
        }
    }

    private static let samplesPerMs = 16
}
