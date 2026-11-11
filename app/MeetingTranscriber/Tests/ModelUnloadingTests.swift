import FluidAudio
@testable import MeetingTranscriber
import WhisperKit
import XCTest

@MainActor
final class ModelUnloadingTests: XCTestCase {
    func testParakeetReleaseDropsTheManagerAndCanLoadAgain() async {
        let engine = ParakeetEngine()
        weak var manager: AsrManager?
        engine.installModelManagerForTesting {
            let loaded = AsrManager(config: .default)
            manager = loaded
            return loaded
        }
        await engine.loadModel()
        XCTAssertNotNil(manager)
        XCTAssertEqual(engine.modelState, .loaded)

        engine.releaseModel()

        XCTAssertNil(manager)
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertEqual(engine.downloadProgress, 0)
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)
    }

    func testReleaseDuringParakeetLoadDiscardsItsResult() async {
        let engine = ParakeetEngine()
        let gate = MainActorGate()
        var loads = 0
        engine.installModelManagerForTesting {
            loads += 1
            await gate.wait()
            return AsrManager(config: .default)
        }
        let old = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter)
        engine.releaseModel()
        gate.open()
        await old.value
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertEqual(engine.downloadProgress, 0)
        XCTAssertEqual(loads, 1)
    }

    func testFreshParakeetCallerRetriesTheInvalidatedLoadItJoined() async {
        let engine = ParakeetEngine()
        let gate = MainActorGate()
        var loads = 0
        engine.installModelManagerForTesting {
            loads += 1
            await gate.wait()
            return AsrManager(config: .default)
        }
        let old = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter)
        engine.releaseModel()
        let fresh = Task {
            gate.open()
            await engine.loadModel()
        }
        await old.value
        await fresh.value
        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(loads, 2)
    }

    func testNewWhisperCallerRetriesAnInvalidatedFailedLoad() async throws {
        let engine = WhisperKitEngine()
        let gate = MainActorGate()
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        var downloads = 0
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                downloads += 1
                if downloads == 1 {
                    await gate.wait()
                    throw URLError(.notConnectedToInternet)
                }
                return URL(fileURLWithPath: "/unused-model")
            },
            makePipe: { _, _ in pipe },
        ))
        let old = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter)
        engine.releaseModel()
        let fresh = Task {
            gate.open()
            await engine.loadModel()
        }
        await old.value
        await fresh.value

        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(downloads, 2)
    }

    func testWhisperReleaseDropsThePipeAndProgress() async throws {
        let engine = WhisperKitEngine()
        try await installModel(on: engine)
        await engine.loadModel()
        XCTAssertTrue(engine.pipeInstalled)

        engine.releaseModel()

        XCTAssertFalse(engine.pipeInstalled)
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertEqual(engine.downloadProgress, 0)
    }

    func testReleaseDuringWhisperLoadDoesNotResurrectOrRetryTheModel() async throws {
        let engine = WhisperKitEngine()
        let gate = MainActorGate()
        var loads = 0
        try await installModel(on: engine) {
            loads += 1
            await gate.wait()
        }
        let load = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter)

        engine.releaseModel()
        gate.open()
        await load.value

        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertFalse(engine.pipeInstalled)
        XCTAssertEqual(loads, 1)
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "An explicit later load must still work")
        XCTAssertEqual(loads, 2)
    }

    // MARK: - Transcribing after a release

    /// The first job after idle reloads through `ensureModel`, not `loadModel()`.
    func testWhisperTranscribeAfterReleaseReloadsTheModel() async throws {
        let engine = WhisperKitEngine()
        var loads = 0
        try await installModel(on: engine) { loads += 1 }
        await engine.loadModel()
        engine.releaseModel()

        // The idle pipe cannot decode; only the reload is under test.
        _ = try? await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/missing.wav"))

        XCTAssertEqual(loads, 2)
        XCTAssertTrue(engine.pipeInstalled)
        XCTAssertEqual(engine.modelState, .loaded)
    }

    func testParakeetTranscribeAfterReleaseReloadsTheModel() async {
        let engine = ParakeetEngine()
        var loads = 0
        engine.installModelManagerForTesting {
            loads += 1
            return AsrManager(config: .default)
        }
        await engine.loadModel()
        engine.releaseModel()

        // The manager has no models to decode with; only the reload is under test.
        _ = try? await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/missing.wav"))

        XCTAssertEqual(loads, 2)
        XCTAssertEqual(engine.modelState, .loaded)
    }

    // MARK: - Generation guards

    func testWhisperDownloadProgressFromAReleasedLoadIsDropped() async {
        let engine = WhisperKitEngine()
        let started = MainActorGate()
        let reported = MainActorGate()
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, progress in
                await started.wait()
                let halfway = Progress(totalUnitCount: 2)
                halfway.completedUnitCount = 1
                progress(halfway)
                // Queued after the progress task on the main actor, so that task has run.
                await Task { @MainActor in }.value
                await reported.wait()
                throw URLError(.notConnectedToInternet)
            },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))
        let load = Task { await engine.loadModel() }
        await waitFor(started.hasWaiter)
        engine.releaseModel()
        started.open()
        await waitFor(reported.hasWaiter)

        XCTAssertEqual(engine.downloadProgress, 0)
        reported.open()
        await load.value
    }

    /// A release has no model to drop during the launch download, so its status stays.
    func testParakeetReleaseDuringTheLaunchDownloadKeepsItsStatus() async {
        let engine = ParakeetEngine()
        let started = MainActorGate()
        let reported = MainActorGate()
        engine.installModelDownloadForTesting(onDisk: false) { report in
            await started.wait()
            report(0.5)
            await reported.wait()
        }
        let download = Task { await engine.downloadModelIfMissing() }
        await waitFor(started.hasWaiter)
        engine.releaseModel()
        started.open()
        await waitFor(reported.hasWaiter)

        XCTAssertEqual(engine.modelState, .downloading)
        XCTAssertEqual(engine.downloadProgress, 0.5)
        reported.open()
        await download.value
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    /// A load released during its download must not go on to the CoreML init.
    func testWhisperReleaseDuringALoadsDownloadSkipsThePipeBuild() async {
        let engine = WhisperKitEngine()
        let gate = MainActorGate()
        var pipeBuilds = 0
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                await gate.wait()
                return URL(fileURLWithPath: "/unused-model")
            },
            makePipe: { _, _ in
                pipeBuilds += 1
                throw WhisperError.modelsUnavailable()
            },
        ))
        let load = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter)
        engine.releaseModel()
        gate.open()
        await load.value

        XCTAssertEqual(pipeBuilds, 0)
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertNil(engine.loadFailureReason)
    }

    /// A release during a failing local load must stop the download fallback.
    func testWhisperReleaseDuringALocalLoadSkipsTheDownloadFallback() async {
        let engine = WhisperKitEngine()
        let gate = MainActorGate()
        var downloads = 0
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in URL(fileURLWithPath: "/unused-model") },
            download: { _, _ in
                downloads += 1
                throw URLError(.notConnectedToInternet)
            },
            makePipe: { _, _ in
                await gate.wait()
                throw WhisperError.modelsUnavailable()
            },
        ))
        let load = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter)
        engine.releaseModel()
        gate.open()
        await load.value

        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    func testWhisperReleaseKeepsTheLoadFailureReason() async throws {
        let engine = WhisperKitEngine()
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))
        await engine.loadModel()
        let reason = try XCTUnwrap(engine.loadFailureReason, "test premise: the load failed with a reason")

        engine.releaseModel()

        XCTAssertEqual(engine.loadFailureReason, reason)
    }

    private func installModel(
        on engine: WhisperKitEngine, beforeAdoption: @escaping @MainActor () async -> Void = {},
    ) async throws {
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in URL(fileURLWithPath: "/unused-model") },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in
                await beforeAdoption()
                return pipe
            },
        ))
    }
}
