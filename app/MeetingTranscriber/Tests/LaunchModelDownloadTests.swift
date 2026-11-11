import FluidAudio
@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// With idle unloading on, launch downloads a missing model and keeps nothing loaded.
@MainActor
final class LaunchModelDownloadTests: XCTestCase {
    /// The one load is what fetches the tokenizer while the machine is online.
    func testLaunchDownloadOfAMissingModelLoadsItOnceThenReleasesIt() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let source = CountingModelSource(onDisk: false)
        try await engines.whisperKit.installModelSourceForTesting(source.make())

        await engines.preloadActiveModel()

        XCTAssertEqual(source.downloads, 1)
        XCTAssertEqual(source.pipeBuilds, 1)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testTheLoadAfterALaunchDownloadIsKeptWhileBusy() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        engines.activateModelLifetime(queue: { nil }, isRecording: { true })
        let source = CountingModelSource(onDisk: false)
        try await engines.whisperKit.installModelSourceForTesting(source.make())

        await engines.preloadActiveModel()

        XCTAssertEqual(source.pipeBuilds, 1)
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
    }

    /// A release has no model to drop during the launch download, so its status stays.
    func testAReleaseDuringTheLaunchDownloadKeepsItsStatusAndFailureReason() async {
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
        let download = Task { await engine.downloadModelIfMissing() }
        await waitFor(started.hasWaiter)
        engine.releaseModel()
        started.open()
        await waitFor(reported.hasWaiter)

        XCTAssertEqual(engine.modelState, .downloading)
        XCTAssertEqual(engine.downloadProgress, 0.5)
        reported.open()
        let downloaded = await download.value
        XCTAssertFalse(downloaded)
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertNotNil(engine.loadFailureReason)
    }

    func testLaunchWithIdleUnloadingLeavesAModelOnDiskAlone() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let source = CountingModelSource(onDisk: true)
        try await engines.whisperKit.installModelSourceForTesting(source.make())

        await engines.preloadActiveModel()

        XCTAssertEqual(source.downloads, 0)
        XCTAssertEqual(source.pipeBuilds, 0)
        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testAFailedLaunchDownloadShowsItsReasonLikeAFailedPreload() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        engines.whisperKit.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))

        await engines.preloadActiveModel()

        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
        XCTAssertNotNil(engines.whisperKit.loadFailureReason)
    }

    func testLaunchWithIdleUnloadingDownloadsAMissingParakeetModelWithoutLoadingIt() async throws {
        for onDisk in [false, true] {
            let settings = try makeIsolatedSettings()
            settings.transcriptionEngine = .parakeet
            let engines = EngineController(settings: settings)
            var downloads = 0
            var loads = 0
            engines.parakeetEngine.installModelManagerForTesting {
                loads += 1
                return AsrManager(config: .default)
            }
            engines.parakeetEngine.installModelDownloadForTesting(onDisk: onDisk) { _ in downloads += 1 }

            await engines.preloadActiveModel()

            XCTAssertEqual(downloads, onDisk ? 0 : 1, "onDisk: \(onDisk)")
            XCTAssertEqual(loads, 0, "onDisk: \(onDisk)")
            XCTAssertEqual(engines.parakeetEngine.modelState, .unloaded, "onDisk: \(onDisk)")
        }
    }

    func testAJobLoadDuringTheLaunchDownloadJoinsItInsteadOfDownloadingAgain() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        // A job keeps the queue busy; without a queue here, recording stands in.
        engines.activateModelLifetime(queue: { nil }, isRecording: { true })
        let gate = MainActorGate()
        let source = CountingModelSource(onDisk: false) { await gate.wait() }
        try await engines.whisperKit.installModelSourceForTesting(source.make())

        let launch = Task { await engines.preloadActiveModel() }
        await waitFor(gate.hasWaiter)
        // A job's entry point; the idle pipe cannot decode, only the load matters.
        let job = Task { _ = try? await engines.whisperKit.transcribeSegments(audioPath: URL(fileURLWithPath: "/missing.wav")) }
        await Task.yield()
        gate.open()
        await launch.value
        await job.value

        XCTAssertEqual(source.downloads, 1)
        XCTAssertEqual(source.pipeBuilds, 1)
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
    }

    func testAJobJoiningAFailedLaunchDownloadFailsWithoutDownloadingAgain() async throws {
        let settings = try makeIsolatedSettings()
        let engines = EngineController(settings: settings)
        let gate = MainActorGate()
        var downloads = 0
        engines.whisperKit.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                downloads += 1
                await gate.wait()
                throw URLError(.notConnectedToInternet)
            },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))

        let launch = Task { await engines.preloadActiveModel() }
        await waitFor(gate.hasWaiter)
        let job = Task { try await engines.whisperKit.transcribeSegments(audioPath: URL(fileURLWithPath: "/missing.wav")) }
        await Task.yield()
        gate.open()
        await launch.value
        let result = await job.result

        XCTAssertEqual(downloads, 1)
        guard case let .failure(error) = result, case .modelNotLoaded? = error as? TranscriptionError else {
            XCTFail("expected modelNotLoaded, got \(result)")
            return
        }
        XCTAssertNotNil(engines.whisperKit.loadFailureReason)
    }

    func testAJobDuringTheParakeetLaunchDownloadLoadsOnlyAfterIt() async throws {
        let settings = try makeIsolatedSettings()
        settings.transcriptionEngine = .parakeet
        let engines = EngineController(settings: settings)
        let gate = MainActorGate()
        var downloads = 0
        var downloaded = false
        var loadsAfterDownload = 0
        var loadsBeforeDownload = 0
        engines.parakeetEngine.installModelManagerForTesting {
            if downloaded { loadsAfterDownload += 1 } else { loadsBeforeDownload += 1 }
            return AsrManager(config: .default)
        }
        engines.parakeetEngine.installModelDownloadForTesting(onDisk: false) { _ in
            downloads += 1
            await gate.wait()
            downloaded = true
        }

        let launch = Task { await engines.preloadActiveModel() }
        await waitFor(gate.hasWaiter)
        // The manager has no models to decode with; only the load matters.
        let job = Task { _ = try? await engines.parakeetEngine.transcribeSegments(audioPath: URL(fileURLWithPath: "/missing.wav")) }
        await Task.yield()
        gate.open()
        await launch.value
        await job.value

        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(loadsBeforeDownload, 0)
        XCTAssertEqual(loadsAfterDownload, 1)
        XCTAssertEqual(engines.parakeetEngine.modelState, .loaded)
    }
}

/// A Hub source whose download makes the model appear on disk.
@MainActor
private final class CountingModelSource {
    private(set) var downloads = 0
    private(set) var pipeBuilds = 0
    private var onDisk: Bool
    private let beforeDownloadEnds: @MainActor () async -> Void

    init(onDisk: Bool, beforeDownloadEnds: @escaping @MainActor () async -> Void = {}) {
        self.onDisk = onDisk
        self.beforeDownloadEnds = beforeDownloadEnds
    }

    func make() async throws -> WhisperKitModelSource {
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        let folder = URL(fileURLWithPath: "/unused-model")
        return WhisperKitModelSource(
            locateLocal: { [self] _ in onDisk ? folder : nil },
            download: { [self] _, _ in
                downloads += 1
                await beforeDownloadEnds()
                onDisk = true
                return folder
            },
            makePipe: { [self] _, _ in
                pipeBuilds += 1
                return pipe
            },
        )
    }
}
