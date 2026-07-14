@testable import MeetingTranscriber
import XCTest

/// Unit tests for `LiveTranscriptionCoordinator.attachSinks`'s gate — that live
/// sinks are installed on the recorder IFF the toggle is on AND the active engine
/// supports streaming.
///
/// This gating was previously buried in `AppState.makeRecorderFactory` (a private
/// closure) and only reachable via live recording / E2E. The `makeController`
/// injection seam lets a test supply a controller built with mock collaborators
/// (`MockStreamingEngine` + `FakeLiveSpeakerMatcher`) so `prepare()` loads no
/// models — making the gate testable in isolation.
///
/// Non-vacuity: the two "skip" tests build the controller with the gate OPEN
/// (so it's cached), then flip the gate CLOSED before `attachSinks`. The sinks
/// stay nil *because of the gate*, not because no controller exists — removing
/// the gate would install them (proven by temporarily deleting the guard).
@MainActor
final class LiveTranscriptionCoordinatorTests: XCTestCase {
    /// Builds a controller with mock collaborators — `prepare()` is a no-op
    /// (mock engine `loadModel`, fake matcher `prepare`), so no model loads.
    /// The EOU factory returns a mock manager that never loads real models, so
    /// the English-streaming branch is exercisable without CoreML downloads.
    private func mockControllerFactory() -> LiveTranscriptionCoordinator.ControllerFactory {
        { engine, captions, engineLanguage, verboseDiagnostics in
            let eouFactory: LiveTranscriptionController.EouSessionFactory = { MockEouManager() }
            let verbose: () -> Bool = { verboseDiagnostics() }
            return LiveTranscriptionController(
                engine: engine,
                vad: FluidVAD(threshold: 0.5),
                captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(),
                engineLanguage: engineLanguage,
                eouSessionFactory: eouFactory,
                verboseDiagnostics: verbose,
            )
        }
    }

    /// Same as `mockControllerFactory` but counts how many controllers it builds,
    /// so tests can assert whether a code path (re)builds a controller (a proxy
    /// for a cold CoreML model load) or reuses the warmed one.
    private func countingControllerFactory()
        -> (LiveTranscriptionCoordinator.ControllerFactory, () -> Int) {
        let counter = ManagedCounter()
        let base = mockControllerFactory()
        let factory: LiveTranscriptionCoordinator.ControllerFactory = { engine, captions, lang, verbose in
            _ = counter.increment()
            return base(engine, captions, lang, verbose)
        }
        return (factory, { counter.value })
    }

    func testAttachSinksInstallsWhenGateOpenAndControllerReady() async {
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() }

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNotNil(recorder.micLiveSink, "gate open + controller ready should install the mic sink")
        XCTAssertNotNil(recorder.appLiveSink, "gate open + controller ready should install the app sink")
    }

    func testAttachSinksSkipsWhenLiveDisabledEvenWithControllerReady() async {
        var enabled = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { enabled },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() } // gate open → controller cached
        enabled = false

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNil(recorder.micLiveSink, "live disabled must skip sink install even with a cached controller")
        XCTAssertNil(recorder.appLiveSink)
    }

    func testAttachSinksSkipsWhenEngineUnsupportedEvenWithControllerReady() async {
        var supportsLive = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { supportsLive },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() } // gate open → controller cached
        supportsLive = false

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNil(recorder.micLiveSink, "unsupported engine must skip sink install even with a cached controller")
        XCTAssertNil(recorder.appLiveSink)
    }

    /// English-streaming opt-in bypasses the engine-support gate: with the
    /// engine reporting no live support, `attachSinks` still installs the sinks
    /// because the EOU sessions are engine-independent. The non-vacuity twin of
    /// `testAttachSinksSkipsWhenEngineUnsupportedEvenWithControllerReady` — same
    /// unsupported engine, but `englishStreaming` ON flips the outcome.
    func testAttachSinksInstallsWhenEngineUnsupportedButEnglishStreamingOn() async {
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { false },
            engineLanguage: { "en" },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
        )
        // Non-streaming engine provider: the EOU path
        // builds a controller with a nil streaming engine, so the sinks still
        // install. `nil` here would short-circuit ensureController before the
        // gate, so use a non-streaming stand-in.
        coordinator.beginPrewarm { NonStreamingEngine() }

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertNotNil(
            recorder.micLiveSink,
            "english streaming must bypass the engine-support gate and install the mic sink",
        )
        XCTAssertNotNil(recorder.appLiveSink)
    }

    // MARK: - No cold-build at the recording edge

    /// `attachSinks` runs at recording start. It must NOT cold-build the
    /// controller there — a cold build kicks a heavy CoreML model load
    /// (Nemotron ~584 MB) from the recorder-start path, landing the compile on
    /// the meeting edge and starving the system. The controller is warmed at
    /// launch/idle instead; if it isn't warmed yet, this recording simply gets
    /// no captions (they come online at the next idle prewarm).
    ///
    /// Non-vacuity: the engine provider IS set (via `beginPrewarm`) and captions
    /// ARE eligible when `attachSinks` runs, so the pre-fix `ensureController()`
    /// path would build one (proven by reverting `attachSinks` to `ensureController`).
    func testAttachSinksDoesNotColdBuildControllerAtRecordingStart() async {
        var enabled = false
        let (factory, buildCount) = countingControllerFactory()
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { enabled },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: factory,
        )
        // Prewarm while captions are disabled: engine provider is wired, but
        // nothing is built (not eligible). Plain-`var` toggles don't fire the
        // @Observable re-warm observer, so the controller stays nil.
        coordinator.beginPrewarm { MockStreamingEngine() }
        XCTAssertEqual(buildCount(), 0, "prewarm with captions disabled must not build a controller")

        enabled = true // captions now eligible, controller still nil

        let recorder = DualSourceRecorder()
        await coordinator.attachSinks(to: recorder)

        XCTAssertEqual(buildCount(), 0, "attachSinks must not cold-build the controller at the recording edge")
        XCTAssertNil(recorder.micLiveSink, "no warmed controller → no sinks this recording")
        XCTAssertNil(recorder.appLiveSink)
    }

    /// The warm path: once the controller is prewarmed, repeated recordings reuse
    /// the SAME instance and never trigger a rebuild (which would recompile models).
    func testWarmedControllerIsReusedAcrossRecordingsWithoutRebuild() async {
        let (factory, buildCount) = countingControllerFactory()
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: factory,
        )
        coordinator.beginPrewarm { MockStreamingEngine() }
        XCTAssertEqual(buildCount(), 1, "prewarm builds the controller once")

        for _ in 0 ..< 3 {
            let recorder = DualSourceRecorder()
            await coordinator.attachSinks(to: recorder)
            XCTAssertNotNil(recorder.micLiveSink)
        }

        XCTAssertEqual(buildCount(), 1, "warm controller must be reused across recordings, never rebuilt")
    }

    // MARK: - Warm-up queue routing

    /// The controller's `prepare()` (its heavy model load) must run through the
    /// injected shared `ModelWarmupQueue`, so it serializes against the ASR
    /// engine preload rather than compiling concurrently.
    ///
    /// Proven by occupying the queue with a blocker: while the blocker holds the
    /// queue, `prepare()` cannot run (no backend published); it only completes
    /// once the blocker is released. If `prepare()` bypassed the queue it would
    /// publish a backend immediately, failing the mid-test `XCTAssertNil`.
    func testControllerPrepareRunsThroughTheSharedWarmupQueue() async {
        let queue = ModelWarmupQueue()
        let captions = LiveCaptionsState()
        let gate = TestGate()
        let blocker = Task { @MainActor in await queue.run { await gate.wait() } }
        // Let the blocker take the queue head before anything is enqueued behind it.
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        let coordinator = LiveTranscriptionCoordinator(
            captions: captions,
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            makeController: mockControllerFactory(),
            warmupQueue: queue,
        )
        coordinator.beginPrewarm { MockStreamingEngine() } // enqueues prepare() behind the blocker

        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNil(
            captions.activeBackend,
            "prepare() must wait behind the queued blocker — proves it routes through the shared queue",
        )

        gate.release()
        var settled = false
        for _ in 0 ..< 500 where !settled {
            if captions.activeBackend != nil { settled = true } else { await Task.yield() }
        }
        XCTAssertTrue(settled, "prepare() should complete and publish its backend once the queue drains")
        _ = await blocker.value
    }
}

/// Manual gate: an enqueued op awaits `wait()` until the test calls `release()`,
/// letting a test hold the warm-up queue head to observe what queues behind it.
@MainActor
private final class TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// A `TranscribingEngine` that does NOT conform to `StreamingTranscribingEngine`
/// — for which the English-streaming path must build a controller with a nil
/// streaming engine.
@MainActor
private final class NonStreamingEngine: TranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1.0
    var transcriptionProgress: Double = 1.0
    func loadModel() {}
    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }
}
