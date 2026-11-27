@testable import MeetingTranscriber
import os
import WhisperKit
import XCTest

/// The local model under the cloud toggle: cloud on counts as idle unloading in
/// `EngineController`'s model lifetime, and no launch preload or download runs.
@MainActor
final class EngineControllerCloudModelTests: XCTestCase {
    func testLaunchWithCloudOnSkipsThePreload() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        settings.cloudTranscriptionEnabled = true
        let engines = EngineController(settings: settings)
        try await installModel(on: engines.whisperKit)

        await engines.preloadActiveModel()

        XCTAssertEqual(engines.whisperKit.modelState, .unloaded, "the local model was loaded with cloud on")
    }

    func testLaunchWithCloudOnSkipsTheMissingModelDownload() async throws {
        let settings = try makeIsolatedSettings()
        settings.cloudTranscriptionEnabled = true
        let engines = EngineController(settings: settings)
        let downloads = DownloadCounter()
        engines.whisperKit.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                await downloads.increment()
                throw URLError(.notConnectedToInternet)
            },
            makePipe: { _, _ in throw URLError(.cannotOpenFile) },
        ))

        await engines.preloadActiveModel()

        let count = await downloads.count
        XCTAssertEqual(count, 0, "a model was downloaded with cloud on")
    }

    func testSwitchingCloudOnReleasesTheLocalModel() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        await engines.preloadActiveModel()
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)

        settings.cloudTranscriptionEnabled = true
        await waitFor(engines.whisperKit.modelState == .unloaded)

        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testSwitchingCloudOnDuringAJobDefersTheReleaseToTheDrain() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        await engines.preloadActiveModel()
        queue.isProcessing = true
        settings.cloudTranscriptionEnabled = true
        engines.syncEngineSettings()
        XCTAssertEqual(engines.whisperKit.modelState, .loaded, "the model was released under a running job")

        await queue.processNext()
        await waitFor(engines.whisperKit.modelState == .unloaded)

        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testSwitchingCloudOffReloadsTheActiveModel() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = false
        settings.cloudTranscriptionEnabled = true
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)

        settings.cloudTranscriptionEnabled = false
        await waitFor(engines.whisperKit.modelState == .loaded)

        XCTAssertEqual(engines.whisperKit.modelState, .loaded)
    }

    func testSwitchingCloudOffWithIdleUnloadingOnLoadsNothing() async throws {
        let settings = try makeIsolatedSettings()
        settings.cloudTranscriptionEnabled = true
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)

        settings.cloudTranscriptionEnabled = false
        engines.syncEngineSettings()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(engines.whisperKit.modelState, .unloaded)
    }

    func testSwitchingCloudOnWithIdleUnloadingOnReleasesALoadedModel() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = true
        let engines = EngineController(settings: settings)
        let queue = try makeIsolatedQueue()
        engines.activateModelLifetime(queue: { queue }, isRecording: { false })
        try await installModel(on: engines.whisperKit)
        await engines.whisperKit.loadModel() // Settings' Load Model
        XCTAssertEqual(engines.whisperKit.modelState, .loaded)

        settings.cloudTranscriptionEnabled = true
        await waitFor(engines.whisperKit.modelState == .unloaded)

        XCTAssertEqual(engines.whisperKit.modelState, .unloaded, "the local model stayed loaded with cloud on")
    }

    func testCloudSwitchedOnWhileTheLaunchDownloadWaitsSkipsIt() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = true
        let warmup = ModelWarmupQueue()
        let engines = EngineController(settings: settings, warmupQueue: warmup)
        let downloads = DownloadCounter()
        engines.whisperKit.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                await downloads.increment()
                throw URLError(.notConnectedToInternet)
            },
            makePipe: { _, _ in throw URLError(.cannotOpenFile) },
        ))
        let held = HeldSlot()
        let holder = Task { await warmup.run("caption warm-up") { await held.wait() } }
        await waitFor(held.isWaiting)
        let preload = Task { await engines.preloadActiveModel() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        settings.cloudTranscriptionEnabled = true
        held.release()
        await holder.value
        await preload.value

        let count = await downloads.count
        XCTAssertEqual(count, 0, "the queued launch download ran after cloud went on")
    }

    func testCloudSwitchedOnDuringTheLaunchDownloadSkipsTheTokenizerLoad() async throws {
        let settings = try makeIsolatedSettings()
        settings.unloadModelsWhenIdle = true
        let engines = EngineController(settings: settings)
        let loads = DownloadCounter()
        let downloaded = OSAllocatedUnfairLock(initialState: false)
        engines.whisperKit.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in downloaded.withLock { $0 } ? URL(fileURLWithPath: "/unused-model") : nil },
            download: { _, _ in
                await MainActor.run { settings.cloudTranscriptionEnabled = true }
                downloaded.withLock { $0 = true }
                return URL(fileURLWithPath: "/unused-model")
            },
            makePipe: { _, _ in
                await loads.increment()
                throw URLError(.cannotOpenFile)
            },
        ))

        await engines.preloadActiveModel()

        let count = await loads.count
        XCTAssertEqual(count, 0, "the tokenizer load ran after cloud went on")
    }

    private func installModel(on engine: WhisperKitEngine) async throws {
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in URL(fileURLWithPath: "/unused-model") },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            makePipe: { _, _ in pipe },
        ))
    }
}

private actor DownloadCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

/// Holds a warm-up slot until released.
@MainActor
private final class HeldSlot {
    var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
