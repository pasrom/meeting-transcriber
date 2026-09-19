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
    }

    /// A WhisperKit instance that loads nothing: `load: false` with
    /// `download: false` keeps the initializer off the network and off CoreML, which
    /// is what lets it stand in for a real pipe in milliseconds.
    private func makeIdlePipe() async throws -> WhisperKit {
        try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
    }

    /// Wire a recording source onto `engine`. The two `Result`s are the whole
    /// variation between the tests, so each test still states its own case at the
    /// call site while the bookkeeping lives here once.
    private func installRecordingSource(
        on engine: WhisperKitEngine,
        local: URL?,
        download: Result<URL, any Error>,
        pipe: Result<WhisperKit, any Error>,
        pipeFailsFor failingFolder: URL? = nil,
    ) -> Recorder {
        let recorder = Recorder()
        engine.installModelSourceForTesting(
            WhisperKitModelSource(
                locateLocal: { _ in local },
                download: { _, _ in
                    recorder.order.append("download")
                    return try download.get()
                },
                makePipe: { _, folder in
                    recorder.order.append("pipe")
                    recorder.pipeFolders.append(folder)
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

    /// The mid-load reconcile, which `adoptPipe` now applies to the local branch too.
    ///
    /// Scenario from production: the launch preload starts on variant A, the user
    /// changes the model in Settings, and the reactive settings sync calls
    /// `applyModelVariant(B)`. With `pipe` still nil, that call can only update the
    /// property, so without the reconcile the finished load would install A while
    /// `modelVariant` says B, and `ensureModel` would short-circuit on the non-nil
    /// pipe and transcribe with the wrong model forever.
    ///
    /// Untested before this test: the reconcile was moved into shared code with no
    /// case that changes the variant, so dropping it kept every other test green.
    func testLoadModelDropsALocallyLoadedPipeWhenTheVariantChangedMidLoad() async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let local = try makeTempDirectory(prefix: "wk-local")
        let idle = try await makeIdlePipe()
        let recorder = Recorder()

        engine.installModelSourceForTesting(
            WhisperKitModelSource(
                locateLocal: { _ in local },
                download: { _, _ in
                    recorder.order.append("download")
                    throw URLError(.networkConnectionLost)
                },
                makePipe: { _, folder in
                    recorder.order.append("pipe")
                    recorder.pipeFolders.append(folder)
                    // The settings change lands while the load is in flight, exactly
                    // where `applyModelVariant` finds a nil pipe and can only record
                    // the new name.
                    engine.applyModelVariant("openai_whisper-tiny")
                    return idle
                },
            ),
        )

        await engine.loadModel()

        XCTAssertEqual(
            engine.modelState, .unloaded,
            "A pipe loaded for the superseded variant must be dropped, so the next transcription reloads the current one",
        )
        XCTAssertEqual(recorder.order, ["pipe"], "The local branch is the one under test, no download involved")
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
}
