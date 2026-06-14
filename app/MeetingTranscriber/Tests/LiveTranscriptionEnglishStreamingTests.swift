import AudioTapLib
@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Behaviour pins for the English low-latency streaming path on
/// `LiveTranscriptionController` — the `englishStreaming` opt-in that routes
/// per-channel captions through `EouStreamingCaptionSession` instead of the
/// VAD + re-transcribe `StreamingTranscriber`, and its non-fatal model-load
/// fallback.
///
/// Observation without visibility widening: the pipelines themselves are
/// private, so each test asserts on the injected seams instead — the EOU
/// session factory's call count (one per channel = 2) and the engine's
/// `loadModel`/`transcribe` activity. The EOU path never touches the engine;
/// the re-transcribe path loads + drives it. Those two signatures distinguish
/// which strategy `prepare()` resolved to.
@MainActor
final class LiveTranscriptionEnglishStreamingTests: XCTestCase {
    /// Counts EOU-backend constructions across both channels and hands back a
    /// `MockEouManager` (optionally one whose `loadModels()` throws).
    private final class EouFactoryProbe {
        private(set) var buildCount = 0
        private let loadError: (any Error)?

        init(loadError: (any Error)? = nil) {
            self.loadError = loadError
        }

        func make() -> any EouStreamingAsrManaging {
            buildCount += 1
            return MockEouManager(loadError: loadError)
        }
    }

    private struct LoadFailure: Error {}

    /// Tracks whether the engine's `loadModel()` ran — the tell that the
    /// re-transcribe path was built (the EOU path skips it entirely).
    private final class LoadTrackingEngine: StreamingTranscribingEngine {
        var modelState: EngineModelState = .loaded
        var downloadProgress: Double = 1.0
        var transcriptionProgress: Double = 1.0
        private(set) var loadModelCount = 0

        func loadModel() {
            loadModelCount += 1
        }

        func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
            []
        }

        func transcribeSamples(_: [Float]) -> String {
            ""
        }
    }

    // MARK: - 1. Factory uses the EOU session when the toggle is on

    func testEnglishStreamingOnBuildsEouSessionsForBothChannels() async {
        let probe = EouFactoryProbe()
        let engine = LoadTrackingEngine()
        // Bound to a local (not a closure literal) so SwiftFormat's
        // trailing-closure rule leaves `eouSessionFactory:` labeled rather than
        // moving it past the trailing `verboseDiagnostics` slot.
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { probe.make() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )

        await controller.prepare()

        XCTAssertEqual(probe.buildCount, 2, "english streaming must build one EOU session per channel (mic + app)")
        XCTAssertEqual(
            engine.loadModelCount, 0,
            "the engine-independent EOU path must NOT load the active engine",
        )
    }

    // MARK: - 2. prepare()-failure fallback to the re-transcribe path

    func testEouLoadFailureFallsBackToReTranscribeWhenEngineSupportsLive() async {
        let probe = EouFactoryProbe(loadError: LoadFailure())
        let engine = LoadTrackingEngine()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { probe.make() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )

        await controller.prepare()

        XCTAssertGreaterThan(probe.buildCount, 0, "the EOU path must have been attempted")
        XCTAssertEqual(
            engine.loadModelCount, 1,
            "EOU load failure must fall back to the re-transcribe path, which loads the engine",
        )
    }

    // MARK: - 3. prepare()-failure with a non-streaming engine → no captions

    func testEouLoadFailureWithNoStreamingEngineYieldsNoCaptions() async {
        // English-streaming opt-in with a non-streaming active engine (e.g.
        // Qwen3) is constructed with a nil streaming engine. If the EOU models
        // fail to load there is nothing to fall back to → captions stay off,
        // and crucially no crash from force-unwrapping a missing engine.
        let probe = EouFactoryProbe(loadError: LoadFailure())
        let captions = LiveCaptionsState()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { probe.make() }
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )

        await controller.prepare()

        XCTAssertGreaterThan(probe.buildCount, 0, "the EOU path must have been attempted")
        // No engine to fall back to → ingesting a buffer produces nothing and
        // doesn't crash (no pipeline was built).
        controller.micSink(LiveAudioBuffer(
            samples: [Float](repeating: 0, count: 16000),
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 0,
        ))
        await Task.yield()
        XCTAssertTrue(captions.recentFinals.isEmpty, "no captions when EOU failed and no engine fallback exists")
    }

    // MARK: - 4. Re-transcribe path untouched when the toggle is off

    func testEnglishStreamingOffBuildsReTranscribePathAndNeverBuildsEou() async {
        let probe = EouFactoryProbe()
        let engine = LoadTrackingEngine()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { probe.make() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: false,
            eouSessionFactory: eouFactory,
        )

        await controller.prepare()

        XCTAssertEqual(probe.buildCount, 0, "english streaming off must never build an EOU session")
        XCTAssertEqual(engine.loadModelCount, 1, "the re-transcribe path loads the active engine")
    }

    // MARK: - 5. Pipeline-construction is single-owner across reset/prepare orderings

    /// (i) reset-then-prepare — the reported bug. `prepareForNextRecording()`
    /// runs BEFORE `prepare()` resolves (the production ordering when a recording
    /// starts before the prewarm Task runs). It must NOT pre-empt the EOU path by
    /// building re-transcribe pipelines; `prepare()` must then still build the EOU
    /// sessions.
    ///
    /// Mutation-proof: branching `prepareForNextRecording()` on the resolved
    /// `usingEnglishStreaming` (false here) instead of the config flag would build
    /// re-transcribe actors, prepare()'s once-guard would skip, and `buildCount`
    /// would stay 0 — the assertion below would fail.
    func testResetBeforePrepareStillBuildsEouSessions() async {
        let probe = EouFactoryProbe()
        let engine = LoadTrackingEngine()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { probe.make() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )

        // Recording starts before prewarm: prepareForNextRecording() runs first.
        await controller.prepareForNextRecording()
        XCTAssertEqual(probe.buildCount, 0, "reset before prepare must build nothing — prepare owns EOU construction")
        XCTAssertEqual(engine.loadModelCount, 0, "reset before prepare must NOT build the re-transcribe path")

        await controller.prepare()
        XCTAssertEqual(probe.buildCount, 2, "prepare() must still build both EOU sessions after an early reset")
        XCTAssertEqual(engine.loadModelCount, 0, "the EOU path must never load the active engine")
    }

    /// (ii) prepare-then-reset — today's happy path. EOU sessions resolved first;
    /// a later reset keeps them (no rebuild → no model reload).
    func testPrepareThenResetKeepsEouSessions() async {
        let probe = EouFactoryProbe()
        let engine = LoadTrackingEngine()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { probe.make() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )

        await controller.prepare()
        XCTAssertEqual(probe.buildCount, 2)

        await controller.prepareForNextRecording()
        XCTAssertEqual(probe.buildCount, 2, "reset must KEEP the EOU sessions (no rebuild → no model reload)")
        XCTAssertEqual(engine.loadModelCount, 0, "kept EOU sessions never touch the engine")
    }

    /// (iii) fallback-then-reset — EOU load failed, controller fell back to the
    /// re-transcribe path. A later reset must refresh the re-transcribe actors
    /// (so no stale VAD/transcriber state carries over) and must NOT retry the
    /// failed EOU load (the load-failure latch is sticky until the controller is
    /// rebuilt). Refresh is proven functionally: a buffer fed after the reset
    /// still finalizes through the live re-transcribe pipeline.
    func testFallbackThenResetRefreshesReTranscribeAndDoesNotRetryEou() async throws {
        let probe = EouFactoryProbe(loadError: LoadFailure())
        let engine = MockStreamingEngine()
        engine.samplesToTranscribe = "fallback utterance"
        let captions = LiveCaptionsState()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { probe.make() }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )

        await controller.prepare()
        let attemptedEouBuilds = probe.buildCount
        XCTAssertGreaterThan(attemptedEouBuilds, 0, "the EOU path must have been attempted before fallback")

        await controller.prepareForNextRecording()
        XCTAssertEqual(probe.buildCount, attemptedEouBuilds, "reset must NOT retry the failed EOU load (sticky latch)")

        // Functional proof the re-transcribe path is live + refreshed after reset:
        // feed a >1 s speech prefix, then flush the pending tail to a final.
        let samples = try await loadSpeechFixture()
        let prefix = Array(samples.prefix(4096 * 5))
        controller.micSink(buffer16k(prefix))
        await waitFor(!captions.hypothesisMic.isEmpty, timeout: .seconds(30))
        await controller.flush()
        await waitFor(!captions.recentFinals.isEmpty, timeout: .seconds(2))
        XCTAssertEqual(
            captions.recentFinals.first { $0.channel == .mic }?.text,
            "fallback utterance",
            "the refreshed re-transcribe pipeline must transcribe after a fallback-then-reset",
        )
    }

    // MARK: - 6. Stop-time flush boundary: next recording awaits the in-flight flush

    /// A kept EOU session is reused across recordings, so a slow stop-time
    /// `flush()` (whose `asr.finish()` runs the model) must complete before the
    /// next recording reuses the session. `prepareForNextRecording()` must await
    /// the in-flight flush rather than returning while `finish()` is still
    /// suspended — otherwise the next recording's ingests interleave with the old
    /// flush on the same actor.
    ///
    /// Deterministic: the mock `finish()` parks on a continuation until the test
    /// releases it. The assertion is that `prepareForNextRecording()` has NOT
    /// returned while the flush is parked, and returns only once it's released.
    /// Mutation-proof: dropping the `await pendingFlush?.value` makes
    /// `prepareForNextRecording()` return immediately → `resetReturned` flips true
    /// before release → the pre-release assertion fails.
    func testResetAwaitsInFlightFlushOfKeptEouSession() async {
        let gate = FinishGate()
        let captions = LiveCaptionsState()
        let eouFactory: LiveTranscriptionController.EouSessionFactory = { GatedFinishEouManager(gate: gate) }
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            englishStreaming: true,
            eouSessionFactory: eouFactory,
        )
        await controller.prepare()

        // Give the session something to flush: feed a buffer through the mic sink
        // and wait for the mock's partial to surface, which proves the ingest
        // landed (ingestedSamples advanced), so flush() reaches asr.finish().
        controller.micSink(buffer16k([Float](repeating: 0.1, count: 16000)))
        await waitFor(!captions.hypothesisMic.isEmpty, timeout: .seconds(5))
        XCTAssertFalse(captions.hypothesisMic.isEmpty, "the mock partial must surface before flushing")

        // Kick the stop-time flush; it parks inside finish().
        let flushTask = Task { await controller.flush() }
        await gate.waitUntilFinishEntered()

        // Start the next recording's reset on a child task and observe whether it
        // returns while the flush is still parked.
        let resetReturned = ResettableFlag()
        let resetTask = Task {
            await controller.prepareForNextRecording()
            await resetReturned.set()
        }
        // Give the reset task ample scheduling opportunities to run to completion
        // IF it didn't await the flush (the mutation). With the fix it stays
        // suspended on `pendingFlush?.value` and never flips the flag. Polling
        // many times (not a fixed two yields) keeps the negative deterministic:
        // a regression that drops the await reliably flips the flag within these
        // iterations, while the correct code can't flip it before release.
        for _ in 0 ..< 200 where await !(resetReturned.value) {
            await Task.yield()
        }
        let returnedWhileParked = await resetReturned.value
        XCTAssertFalse(
            returnedWhileParked,
            "prepareForNextRecording() must NOT return while the kept session's flush is still in finish()",
        )

        // Release finish(); now both the flush and the reset must complete.
        await gate.release()
        await flushTask.value
        await resetTask.value
        let returnedAfterRelease = await resetReturned.value
        XCTAssertTrue(returnedAfterRelease, "reset must return once the in-flight flush completes")
    }

    // MARK: - Helpers

    private func buffer16k(_ samples: [Float]) -> LiveAudioBuffer {
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

// MARK: - Flush-boundary test doubles

/// Async gate so the mock `finish()` can park until the test releases it, and the
/// test can wait until `finish()` has actually been entered.
private actor FinishGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called from the mock `finish()` — records entry, wakes any entry-waiter,
    /// then parks until `release()`.
    func park() async {
        entered = true
        for waiter in enteredWaiters {
            waiter.resume()
        }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilFinishEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
}

/// EOU mock whose `finish()` parks on a `FinishGate` to widen the stop→start
/// window deterministically. Load succeeds; `processBufferedAudio()` fires a
/// partial so the test can observe that an ingest landed (the session advances
/// `ingestedSamples`, so a subsequent `flush()` reaches `finish()`).
private actor GatedFinishEouManager: EouStreamingAsrManaging {
    private let gate: FinishGate
    private var partialCallback: (@Sendable (String) -> Void)?
    init(gate: FinishGate) {
        self.gate = gate
    }

    func loadModels() {}
    // swiftlint:disable:next unneeded_throws_rethrows
    func appendAudio(_: AVAudioPCMBuffer) throws {}
    // swiftlint:disable:next async_without_await
    func processBufferedAudio() async {
        partialCallback?("typing")
    }

    func finish() async -> String {
        await gate.park()
        return ""
    }

    // swiftlint:disable:next async_without_await
    func reset() async {}
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) {
        partialCallback = callback
    }

    func setEouCallback(_: @Sendable (String) -> Void) {}
    func getEouTimestampsMs() -> [Int] {
        []
    }
}

/// Flag the reset child task flips on return, read by the test. An actor so the
/// cross-task read/write is properly synchronized (and genuinely `await`-ed).
private actor ResettableFlag {
    private(set) var value = false
    func set() {
        value = true
    }
}
