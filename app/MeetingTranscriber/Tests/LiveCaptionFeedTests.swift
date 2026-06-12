import AudioTapLib
@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Contract pins for the per-channel caption feed in
/// `LiveTranscriptionController`: the sink → pipeline handoff must deliver
/// buffers **in order**, process **everything delivered before `flush()`**
/// before the pipeline's flush runs, drop deliveries **after** flush, and
/// bound its buffering when the pipeline stalls (newest buffers win).
///
/// These properties used to be approximated inside the pipeline actors with
/// re-entrancy guards (the production driver spawned one unstructured `Task`
/// per buffer, so ordering and stop-completeness were scheduler luck). They
/// are now properties of the channel itself — one bounded `AsyncStream` per
/// channel with a single consumer — and this suite pins them at the boundary
/// where the recorder hands buffers over.
///
/// Observation point: the English-streaming path with a mock EOU manager —
/// every `ingest` lands as exactly one `appendAudio` on the manager, and
/// `flush()` lands as `finish()`, so append order/count vs. finish position
/// reads the feed's behavior without touching pipeline internals.
///
/// All scenarios share one `@MainActor` class; no CoreML, no fixtures —
/// fully deterministic.
@MainActor
final class LiveCaptionFeedTests: XCTestCase {
    // MARK: - 1. Ordering + completeness before flush

    /// Every buffer handed to the sink before `flush()` must reach the
    /// pipeline, in delivery order, BEFORE the pipeline's flush runs. With
    /// the old Task-per-buffer handoff, sink deliveries still sitting in
    /// unstarted tasks when `flush()` ran were finalized late or lost.
    func testFlushProcessesEveryBufferDeliveredBeforeItInOrder() async {
        let factory = ChannelMockFactory()
        let controller = makeController(factory: factory)
        await controller.prepare()

        let count = 200
        for i in 0 ..< count {
            controller.micSink(buffer(value: Float(i)))
        }
        await controller.flush()

        let appended = await factory.mic.appendedFirstSamples
        XCTAssertEqual(
            appended, (0 ..< count).map(Float.init),
            "every pre-flush buffer must reach the pipeline, in delivery order",
        )
        let atFinish = await factory.mic.appendedCountAtFinish
        XCTAssertEqual(
            atFinish, count,
            "the pipeline flush must run only after every delivered buffer was ingested",
        )
    }

    // MARK: - 2. Post-flush deliveries are dropped

    /// After `flush()` the recording is over — a straggler buffer from the
    /// stopping recorder must not be ingested into the flushed pipeline.
    func testSinkDeliveriesAfterFlushAreDropped() async {
        let factory = ChannelMockFactory()
        let controller = makeController(factory: factory)
        await controller.prepare()

        controller.micSink(buffer(value: 1))
        await controller.flush()
        let before = await factory.mic.appendedFirstSamples.count

        controller.micSink(buffer(value: 99))
        // Give a (hypothetical) stray ingest hop ample time to land.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let after = await factory.mic.appendedFirstSamples.count
        XCTAssertEqual(
            after, before,
            "a buffer delivered after flush() must be dropped, not ingested into the flushed pipeline",
        )
    }

    // MARK: - 3. Bounded buffering under a stalled pipeline

    /// When the pipeline stalls (slow inference), the feed must NOT queue
    /// unboundedly — it keeps the newest buffers and drops the oldest, so a
    /// stall degrades captions instead of growing memory without limit.
    func testStalledPipelineBoundsBufferingAndKeepsNewest() async {
        let factory = ChannelMockFactory()
        let controller = makeController(factory: factory)
        await controller.prepare()

        // Park the pipeline inside its first ingest, then pile up deliveries.
        await factory.mic.setBlockNextProcess(true)
        controller.micSink(buffer(value: 0))
        await factory.mic.waitUntilBlocked()

        let total = 2000
        for i in 1 ..< total {
            controller.micSink(buffer(value: Float(i)))
        }
        await factory.mic.releaseProcess()
        await controller.flush()

        let appended = await factory.mic.appendedFirstSamples
        XCTAssertLessThan(
            appended.count, total,
            "a stalled pipeline must drop buffers instead of queueing without bound",
        )
        XCTAssertEqual(
            appended.last, Float(total - 1),
            "the newest delivery must survive the drop (oldest are discarded first)",
        )
        // Beyond the first (parked) buffer, the survivors must be the newest
        // contiguous run — proving drops happened at the old end only.
        let tail = Array(appended.dropFirst())
        if let first = tail.first {
            let expected = Array(stride(from: first, through: Float(total - 1), by: 1))
            XCTAssertEqual(tail, expected, "kept buffers must be the newest contiguous run, in order")
        } else {
            XCTFail("at least the newest buffers must have been ingested after release")
        }
    }

    // MARK: - 4. Feed rebinds for the next recording

    /// `flush()` retires the feed; `prepareForNextRecording()` must arm a
    /// fresh one so the next recording's sink deliveries flow again (the EOU
    /// sessions are kept across recordings, so this pins the re-arm, not a
    /// rebuild).
    func testFeedRebindsForNextRecording() async {
        let factory = ChannelMockFactory()
        let controller = makeController(factory: factory)
        await controller.prepare()

        controller.micSink(buffer(value: 1))
        await controller.flush()
        let before = await factory.mic.appendedFirstSamples.count

        await controller.prepareForNextRecording()
        controller.micSink(buffer(value: 7))

        await waitFor { await factory.mic.appendedFirstSamples.count > before }
        let appended = await factory.mic.appendedFirstSamples
        XCTAssertEqual(
            appended.last, 7,
            "after prepareForNextRecording() the sink must feed the (kept) pipeline again",
        )
    }

    // MARK: - Helpers

    private func makeController(factory: ChannelMockFactory) -> LiveTranscriptionController {
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { factory.make() }
        return LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )
    }

    /// A 16-sample 16 kHz mono buffer whose samples all carry `value` so the
    /// mock can identify it by its first sample.
    private func buffer(value: Float) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: [Float](repeating: value, count: 16),
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 0,
        )
    }
}

// MARK: - Test doubles

/// Hands the mic mock to the first factory call and the app mock to the
/// second — matching `buildEnglishStreamingPipelines`' construction order.
@MainActor
private final class ChannelMockFactory {
    let mic = MockFeedAsrManager()
    let app = MockFeedAsrManager()
    private var calls = 0

    func make() -> any EouStreamingAsrManaging {
        calls += 1
        return calls == 1 ? mic : app
    }
}

/// EOU-manager mock that records the first sample of every `appendAudio`
/// buffer (the feed tests tag each buffer with a distinct constant value) and
/// the append count at the moment `finish()` runs. `processBufferedAudio()`
/// can park once on a gate so a test can pile deliveries onto a stalled
/// pipeline deterministically.
private actor MockFeedAsrManager: EouStreamingAsrManaging {
    private(set) var appendedFirstSamples: [Float] = []
    private(set) var appendedCountAtFinish = -1

    private var blockNextProcess = false
    private var processContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func setBlockNextProcess(_ value: Bool) {
        blockNextProcess = value
    }

    /// Suspends until `processBufferedAudio()` has actually parked.
    func waitUntilBlocked() async {
        if processContinuation != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func releaseProcess() {
        processContinuation?.resume()
        processContinuation = nil
    }

    // MARK: EouStreamingAsrManaging

    func loadModels() {}

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData, buffer.frameLength > 0 {
            appendedFirstSamples.append(channel[0][0])
        }
    }

    func processBufferedAudio() async {
        guard blockNextProcess else { return }
        blockNextProcess = false
        await withCheckedContinuation { continuation in
            processContinuation = continuation
            for waiter in blockedWaiters {
                waiter.resume()
            }
            blockedWaiters.removeAll()
        }
    }

    func finish() -> String {
        appendedCountAtFinish = appendedFirstSamples.count
        return ""
    }

    func reset() {}

    func setPartialCallback(_: @Sendable (String) -> Void) {}
    func setEouCallback(_: @Sendable (String) -> Void) {}

    func getEouTimestampsMs() -> [Int] {
        []
    }
}
