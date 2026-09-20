@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// Issue #736: with huggingface.co unreachable, `loadModel()` failed even though
/// the model sat complete on disk. Reason on `WhisperKitLocalSnapshot`.
///
/// These tests drive the three load steps through `WhisperKitModelSource` so they
/// can assert which of them ran. Nothing here touches the network or CoreML.
@MainActor
final class WhisperKitEngineModelSourceTests: XCTestCase {
    /// Which steps ran, in order, plus the folders handed to the pipe. One shape of
    /// evidence for every test, so a missing step cannot hide behind a counter that
    /// happens to match.
    private final class Recorder {
        var order: [String] = []
        var pipeFolders: [URL] = []
        /// Which variants reached `makePipe`, in order. Separate from `order` so the
        /// existing step-order assertions stay untouched.
        var pipeVariants: [String] = []
        /// Which variants reached `download`, in order. Same reason, and it is what
        /// lets a test name the variant a retry ran for when no pipe was ever built.
        var downloadVariants: [String] = []
    }

    /// A WhisperKit instance that loads nothing: `load: false` with
    /// `download: false` keeps the initializer off the network and off CoreML, which
    /// is what lets it stand in for a real pipe in milliseconds.
    private func makeIdlePipe() async throws -> WhisperKit {
        try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
    }

    /// Wire a recording source onto `engine`. The `Result`s are the whole variation
    /// between the tests, so each test still states its own case at the call site
    /// while the bookkeeping lives here once.
    ///
    /// `onDownload` and `onPipe` run inside the step they are named after, once it
    /// has been recorded and before it returns or throws. That is where a test lets
    /// a variant change land mid-flight, or parks the load so a second caller can
    /// join it.
    ///
    /// Both are always passed with their label, which is why the call sites turn
    /// `trailing_closure` off rather than following it. Measured: an unlabelled
    /// trailing closure binds to `onDownload` whatever shape it has, so the two
    /// pipe hooks cannot be written that way at all (the closure takes an argument
    /// the bound parameter does not), and writing the download hook that way would
    /// drop the one word that says which of the two steps is being hooked.
    private func installRecordingSource(
        on engine: WhisperKitEngine,
        local: URL?,
        download: Result<URL, any Error>,
        pipe: Result<WhisperKit, any Error>,
        pipeFailsFor failingFolder: URL? = nil,
        onDownload: (@MainActor () async -> Void)? = nil,
        onPipe: (@MainActor (String) async -> Void)? = nil,
    ) -> Recorder {
        let recorder = Recorder()
        engine.installModelSourceForTesting(
            WhisperKitModelSource(
                locateLocal: { _ in local },
                download: { variant, _ in
                    recorder.order.append("download")
                    recorder.downloadVariants.append(variant)
                    await onDownload?()
                    return try download.get()
                },
                makePipe: { variant, folder in
                    recorder.order.append("pipe")
                    recorder.pipeFolders.append(folder)
                    recorder.pipeVariants.append(variant)
                    await onPipe?(variant)
                    if let failingFolder, folder == failingFolder {
                        throw WhisperError.modelsUnavailable()
                    }
                    return try pipe.get()
                },
            ),
        )
        return recorder
    }

    /// The load-bearing test. A complete local snapshot must produce a loaded engine
    /// without a single Hub call, so the download step is wired to throw the very
    /// error the reporter saw: if it runs at all, the test fails.
    func testLoadModelPrefersTheLocalSnapshotAndNeverDownloads() async throws {
        let engine = WhisperKitEngine()
        let local = try makeTempDirectory(prefix: "wk-local")
        let recorder = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
        )

        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .loaded, "A complete local snapshot must load")
        XCTAssertEqual(
            recorder.order, ["pipe"],
            "The Hub must not be contacted when the model is already on disk: that call is what fails behind a firewall",
        )
        XCTAssertEqual(recorder.pipeFolders, [local], "The pipe must be built from the local folder")
        XCTAssertEqual(engine.downloadProgress, 1.0, accuracy: 0.001)
    }

    /// The guard against a silent regression in the other direction: a missing model
    /// must still download exactly as before.
    func testLoadModelDownloadsWhenNoLocalSnapshotExists() async throws {
        let engine = WhisperKitEngine()
        let downloaded = try makeTempDirectory(prefix: "wk-downloaded")
        let recorder = try await installRecordingSource(
            on: engine,
            local: nil,
            download: .success(downloaded),
            pipe: .success(makeIdlePipe()),
        )

        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(recorder.order, ["download", "pipe"], "Without a local copy the download must still run")
        XCTAssertEqual(recorder.pipeFolders, [downloaded])
    }

    /// A complete-looking but unusable local copy (corrupt weights, a layout CoreML
    /// rejects) must not strand the user: the download repairs it.
    func testLoadModelFallsBackToDownloadWhenTheLocalInitFails() async throws {
        let engine = WhisperKitEngine()
        let local = try makeTempDirectory(prefix: "wk-local")
        let downloaded = try makeTempDirectory(prefix: "wk-downloaded")
        let recorder = try await installRecordingSource(
            on: engine,
            local: local,
            download: .success(downloaded),
            pipe: .success(makeIdlePipe()),
            pipeFailsFor: local,
        )

        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(
            recorder.order, ["pipe", "download", "pipe"],
            "The local attempt comes first, and its failure must hand over to the download",
        )
        XCTAssertEqual(recorder.pipeFolders, [local, downloaded])
    }

    /// Offline plus an unusable local copy is the one case with no way out, and it
    /// must fail visibly rather than parking the engine mid-load.
    func testLoadModelFailsVisiblyWhenLocalIsUnusableAndTheHubIsUnreachable() async {
        let engine = WhisperKitEngine()
        let local = URL(fileURLWithPath: "/nonexistent/wk-local")
        let recorder = installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .failure(WhisperError.modelsUnavailable()),
        )

        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .unloaded, "A dead end must reset to .unloaded, not stay .loading")
        XCTAssertEqual(engine.downloadProgress, 0, accuracy: 0.001)
        XCTAssertEqual(
            recorder.order, ["pipe", "download"],
            "The download must still be attempted before giving up",
        )
    }

    /// A failed *reload* must not report `.unloaded` while the previous pipe is still
    /// installed and still serving transcriptions.
    ///
    /// `unloadModel` states the intent: the load `catch` deliberately keeps a
    /// still-good pipe rather than clobbering it. The state it left behind said the
    /// opposite, so Settings offered "Load Model" and `/state` reported `unloaded`
    /// while `ensureModel` short-circuited on the non-nil pipe and kept transcribing.
    /// Automation reading `/state` would conclude the preload failed.
    ///
    /// Older than the local-first path, but that path added a second way to reach it:
    /// the local attempt can now fail before the download does. Reachable in
    /// production because the live-captions setup calls `loadModel()` without a pipe
    /// guard.
    func testFailedReloadKeepsTheStateOfAStillUsablePipe() async throws {
        let engine = WhisperKitEngine()
        let local = try makeTempDirectory(prefix: "wk-local")
        _ = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
        )
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Precondition: a model is loaded")

        // Now every route fails, which is what a reload behind a filtering firewall
        // looks like once the local copy has also gone bad.
        let recorder = installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .failure(WhisperError.modelsUnavailable()),
        )
        await engine.loadModel()

        XCTAssertEqual(
            recorder.order, ["pipe", "download"],
            "Precondition: the reload really did try both routes and fail",
        )
        XCTAssertEqual(
            engine.modelState, .loaded,
            "The prior pipe is deliberately kept, so the state must not claim the engine is unloaded",
        )
        XCTAssertEqual(
            engine.downloadProgress, 1.0, accuracy: 0.001,
            "Progress must match the kept pipe, not the failed attempt",
        )
    }

    // MARK: - Superseded loads (issue #738)

    /// A load serves the variant it snapshotted at its start. When the user changes
    /// the model while a load is in flight, that load is superseded: `adoptPipe`
    /// correctly drops the pipe it built for the old variant, but the caller used to
    /// return with nothing loaded, and `ensureModel` then threw `modelNotLoaded`.
    ///
    /// This is the single-caller half of the problem, which needs no second caller at
    /// all: the launch preload suspends, Settings changes the variant, and the job
    /// that triggered the load fails once.
    ///
    /// Two changes rather than one, because that is what rules out a single retry:
    /// the retry itself can be superseded. With a one-shot retry the chain ends
    /// unloaded, so the condition has to be "keep going while the attempt was for a
    /// variant that is no longer the current one" rather than a fixed number of
    /// tries. The one-change case is the first two links of this chain, which is why
    /// it has no test of its own.
    ///
    /// It also carries what a separate reconcile test used to assert: if `adoptPipe`
    /// stopped dropping the pipe built for the superseded variant, the first pass
    /// would leave a non-nil pipe, no retry would run, and `pipeVariants` would stay
    /// at one entry.
    func testLoadModelFollowsTheVariantAcrossChangesMidLoad() async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let local = try makeTempDirectory(prefix: "wk-local")
        let recorder = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
            // swiftlint:disable:next trailing_closure
            onPipe: { variant in
                // The settings change lands while this load is in flight, where
                // `applyModelVariant` finds a nil pipe and can only record the new
                // name.
                switch variant {
                case "openai_whisper-small": engine.applyModelVariant("openai_whisper-tiny")
                case "openai_whisper-tiny": engine.applyModelVariant("openai_whisper-base")
                default: break
                }
            },
        )

        await engine.loadModel()

        XCTAssertEqual(
            recorder.pipeVariants,
            ["openai_whisper-small", "openai_whisper-tiny", "openai_whisper-base"],
            "Each superseded attempt must be followed by one for the variant current at that point",
        )
        XCTAssertEqual(
            recorder.order, ["pipe", "pipe", "pipe"],
            "Every pass must load locally. Carried over from the reconcile test this replaces: a "
                + "superseded local load falling through to the download would re-fetch the variant nobody "
                + "wants any more, and nothing else covers that",
        )
        XCTAssertEqual(
            engine.modelState, .loaded,
            "Returning unloaded here is what makes the next transcription fail with modelNotLoaded",
        )
    }

    /// The joined half, which is what #738 describes. The second caller must not be
    /// left with the result of a flight that was for a variant nobody wants any more.
    ///
    /// Ordering is fixed by construction rather than by yielding: the joiner resumes
    /// the parked first load itself, which only enqueues it on this actor, so the
    /// joiner keeps the actor until its own first real suspension, and that is the
    /// join inside `SingleFlight`. `MainActorGate.open()` is synchronous for exactly
    /// that reason.
    func testAJoinedSupersededLoadEndsWithTheCurrentVariantLoaded() async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let local = try makeTempDirectory(prefix: "wk-local")
        let parked = expectation(description: "first load parked in makePipe")
        let gate = MainActorGate()
        let recorder = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
            // swiftlint:disable:next trailing_closure
            onPipe: { variant in
                // Park the first pass only. The variant is what says which pass this
                // is: the retry runs for the one the test switches to below.
                guard variant == "openai_whisper-small" else { return }
                parked.fulfill()
                await gate.wait()
            },
        )

        let first = Task { @MainActor in await engine.loadModel() }
        await fulfillment(of: [parked], timeout: 2)
        engine.applyModelVariant("openai_whisper-tiny")

        let joiner = Task { @MainActor in
            gate.open()
            await engine.loadModel()
        }
        await first.value
        await joiner.value

        XCTAssertEqual(
            recorder.pipeVariants, ["openai_whisper-small", "openai_whisper-tiny"],
            "The joiner must end up with the current variant loaded, and the dedup must build it only once",
        )
        XCTAssertEqual(engine.modelState, .loaded)
    }

    /// The guard in the other direction, and the one that rules out the simpler
    /// "retry whenever the pipe is nil" rule: a load that failed for the variant that
    /// is *still* requested must not be repeated, whether the caller ran it or joined
    /// it. Repeating it would double the wait and the failed download for every
    /// caller that arrives during an offline load.
    func testAJoinedLoadThatFailedForTheCurrentVariantIsNotRepeated() async {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let parked = expectation(description: "first load parked in download")
        // Both passes are for the same variant here, so the variant cannot say which
        // pass this is and the gate carries it: it is already open when a second pass
        // arrives. Over-fulfilment is allowed so that a repeat fails on the assertion
        // below rather than trapping before it.
        parked.assertForOverFulfill = false
        let gate = MainActorGate()
        let recorder = installRecordingSource(
            on: engine,
            local: nil,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .failure(WhisperError.modelsUnavailable()),
            // swiftlint:disable:next trailing_closure
            onDownload: {
                parked.fulfill()
                await gate.wait()
            },
        )

        let first = Task { @MainActor in await engine.loadModel() }
        await fulfillment(of: [parked], timeout: 2)
        let joiner = Task { @MainActor in
            gate.open()
            await engine.loadModel()
        }
        await first.value
        await joiner.value

        XCTAssertEqual(
            recorder.order, ["download"],
            "The joiner observed a failure for the variant it wanted, so it must not download again",
        )
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    /// The variant comparison in `loadModel` is handed the engine's *current*
    /// variant, and that argument needs a test of its own. A failed attempt for a
    /// superseded variant is the only case the comparison decides alone, and it is
    /// the download path: an attempt that got as far as building a pipe is carried
    /// by `builtPipe` instead, whatever the variants say.
    ///
    /// `LoadAttemptTests` pins the rule but cannot pin what the engine passes into
    /// it. Handing `needsAnotherAttempt` the attempt's own variant instead of the
    /// requested one leaves every other test in this file green, which is how the
    /// gap was found.
    func testAFailedLoadForASupersededVariantIsRetriedForTheCurrentOne() async {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let recorder = installRecordingSource(
            on: engine,
            local: nil,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .failure(WhisperError.modelsUnavailable()),
            // swiftlint:disable:next trailing_closure
            onDownload: {
                // The settings change lands while the first download is in flight,
                // and only then: the retry has to be allowed to finish.
                if engine.modelVariant == "openai_whisper-small" {
                    engine.applyModelVariant("openai_whisper-tiny")
                }
            },
        )

        await engine.loadModel()

        XCTAssertEqual(
            recorder.downloadVariants, ["openai_whisper-small", "openai_whisper-tiny"],
            "A download that failed for a variant nobody wants any more leaves the requested one untried",
        )
        XCTAssertEqual(
            engine.modelState, .unloaded,
            "Both attempts failed, so the engine must end up reporting that",
        )
    }
}
