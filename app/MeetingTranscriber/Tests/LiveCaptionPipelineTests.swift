import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Coverage for the `LiveCaptionPipeline.flush()` contract: when recording
/// stops mid-utterance (no trailing silence → no VAD `speechEnd` event), the
/// pending speech must still be committed as a final so the user sees the
/// last caption. Without `flush()`, that tail utterance is silently dropped.
///
/// Drives a real `StreamingTranscriber` through the real `FluidVAD` streaming
/// state machine — the same wiring the production path uses. The German
/// two-speaker fixture starts with a `speechStart` at chunk 0 and its first
/// `speechEnd` only at ~8.4 s, so feeding a bounded prefix (a handful of
/// 4096-sample chunks) leaves speech *buffered but not yet finalized* — the
/// exact "recording stopped mid-utterance" condition. `flush()` then has to
/// commit that buffer through `commitFinal()`.
///
/// Both test methods live in one `@MainActor` class (and the actor-level test
/// folds its three scenarios into a single method) on purpose — under
/// `swift test --parallel` each method runs in its own worker process, and the
/// Silero VAD load is the dominant cost. Folding minimises VAD loads and avoids
/// piling parallel-load pressure on the neighbouring CoreML-heavy
/// live-transcription suites. See
/// `feedback_coreml_e5rt_cache_race_under_parallel_xctest`.
@MainActor
final class LiveCaptionPipelineTests: XCTestCase {
    /// Number of 16 kHz mono samples per VAD chunk (Silero v6).
    private static let chunkSize = 4096

    /// Actor-level: `StreamingTranscriber.flush()` commits the pending utterance
    /// (positive) and respects the sub-1 s noise guard (negative).
    func testFlushCommitsPendingUtteranceContract() async throws {
        let samples = try await loadSpeechFixture()

        // (1) Positive: feed ~1.3 s of speech-active prefix (5 chunks). The
        // fixture's first speechEnd is at ~8.4 s, so no end event fires and
        // ~20 480 samples (> the 1 s `minFinalSamples` guard) stay buffered.
        // flush() must emit exactly one finalized event carrying that audio.
        let speakingPrefix = Array(samples.prefix(Self.chunkSize * 5))
        let positive = OnEventRecorder()
        let pipeline = makePipeline(observer: positive)
        await pipeline.ingest(buffer(speakingPrefix))
        XCTAssertEqual(
            positive.finals.count, 0,
            "no speechEnd yet — nothing should be finalized before flush",
        )

        await pipeline.flush()

        XCTAssertEqual(
            positive.finals.count, 1,
            "flush must commit the pending >1 s utterance as exactly one final",
        )
        XCTAssertEqual(
            positive.finals.first?.audio.count, speakingPrefix.count,
            "the finalized event must carry the buffered speech samples",
        )

        // (2) Negative: feed only ~0.77 s of speech-active prefix (3 chunks =
        // 12 288 samples, below the 1 s `minFinalSamples` noise guard). flush()
        // must drop it — sub-second pending speech is treated as noise, same
        // as a real speechEnd would.
        let noisePrefix = Array(samples.prefix(Self.chunkSize * 3))
        let negative = OnEventRecorder()
        let noisePipeline = makePipeline(observer: negative)
        await noisePipeline.ingest(buffer(noisePrefix))
        XCTAssertEqual(negative.finals.count, 0)

        await noisePipeline.flush()

        XCTAssertEqual(
            negative.finals.count, 0,
            "flush must NOT finalize sub-1 s pending speech (noise guard preserved)",
        )
    }

    /// Controller-level: `LiveTranscriptionController.flush()` must propagate to
    /// both channel pipelines so a pending tail utterance reaches
    /// `LiveCaptionsState`. Uses `MockStreamingEngine` (no model load) + the real
    /// `FluidVAD` + the real fixture, driving audio through `micSink` the same
    /// way the recorder does in production.
    ///
    /// Non-vacuity: without `flush()` propagation the pending speech (fed
    /// mid-utterance, no `speechEnd`) never finalises, so `recentFinals` stays
    /// empty — the assertion only passes because flush commits it.
    func testControllerFlushDeliversPendingFinalToCaptions() async throws {
        let samples = try await loadSpeechFixture()
        let captions = LiveCaptionsState()
        let engine = MockStreamingEngine()
        engine.samplesToTranscribe = "tail utterance"
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
        )
        await controller.prepare()

        // Feed a >1 s speech-active prefix through the mic sink (the recorder's
        // entry point). The sink hops onto an actor Task — wait for the partial
        // the prefix emits as the deterministic drain signal. A fixed sleep is
        // not enough: on a cold CI runner the first Silero load inside ingest
        // takes seconds, the actor suspends in the VAD load (reentrancy), and
        // an early flush() would commit an empty buffer.
        let prefix = Array(samples.prefix(Self.chunkSize * 5))
        controller.micSink(buffer(prefix))
        await waitFor(!captions.hypothesisMic.isEmpty, timeout: .seconds(30))
        XCTAssertFalse(captions.hypothesisMic.isEmpty, "ingestion must surface a partial before flushing")
        // No speechEnd yet → nothing finalised before flush.
        XCTAssertTrue(captions.recentFinals.isEmpty, "no final should appear before flush")

        await controller.flush()
        await waitFor(!captions.recentFinals.isEmpty, timeout: .seconds(2))

        let micFinals = captions.recentFinals.filter { $0.channel == .mic }
        XCTAssertEqual(
            micFinals.count, 1,
            "controller.flush() must deliver the pending mic-channel final to captions",
        )
        XCTAssertEqual(micFinals.first?.text, "tail utterance")
    }

    // MARK: - Helpers

    private func makePipeline(observer: OnEventRecorder) -> StreamingTranscriber {
        StreamingTranscriber(
            channelLabel: "test",
            vad: FluidVAD(threshold: 0.5),
            transcribe: { samples in
                // Non-empty so `commitFinal` reaches the `onEvent(.finalized)`
                // emission (it skips emission on empty transcripts).
                samples.isEmpty ? "" : "transcribed"
            },
            onEvent: { event in observer.record(event) },
        )
    }

    private func buffer(_ samples: [Float]) -> LiveAudioBuffer {
        LiveAudioBuffer(samples: samples, channelCount: 1, sampleRate: 16000, hostTime: 0)
    }

    private func loadSpeechFixture() async throws -> [Float] {
        let url = fixtureURL("two_speakers_de.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Test fixture not found at \(url.path)",
        )
        return try await loadFixtureAs16kMono(url)
    }
}

/// Sendable, lock-protected recorder for the actor's `@Sendable` callbacks.
private final class OnEventRecorder: @unchecked Sendable {
    struct Final {
        let text: String
        let audio: [Float]
    }

    private let lock = NSLock()
    private var _finals: [Final] = []

    var finals: [Final] {
        lock.lock(); defer { lock.unlock() }
        return _finals
    }

    func record(_ event: StreamingTranscriber.Event) {
        lock.lock(); defer { lock.unlock() }
        if case let .finalized(text, audio) = event {
            _finals.append(Final(text: text, audio: audio))
        }
    }
}
