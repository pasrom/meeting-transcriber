import CoreML
import FluidAudio
@testable import MeetingTranscriber
import os
import XCTest

private typealias NemotronLoader = (MLComputeUnits) -> (any NemotronStreamingDiarizing, MLComputeUnits)

/// The Nemotron 3 diarization mode without its model: the pure parts, and
/// the streaming glue in `FluidDiarizer+Nemotron.swift` driven through a stub
/// loader. The real model load runs only under `RUN_QUALITY_TESTS=1`
/// (`FluidDiarizerQualityTests`, `SortformerEmbeddingsE2ETests`).
final class FluidDiarizerNemotronTests: XCTestCase {
    func testFluidDiarizerAcceptsNemotronMode() {
        XCTAssertEqual(FluidDiarizer(mode: .nemotron).mode, .nemotron)
    }

    /// Here rather than in `AppSettingsTests`, which sits at the
    /// `file_length` limit.
    func testDiarizerModePersistsNemotron() throws {
        let suiteName = "nemotron-diarizer-mode-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))

        AppSettings(defaults: defaults).diarizerMode = .nemotron
        XCTAssertEqual(defaults.string(forKey: "diarizerMode"), "nemotron")
        XCTAssertEqual(AppSettings(defaults: defaults).diarizerMode, .nemotron)
    }

    func testNemotronShortLabels() {
        XCTAssertEqual(DiarizerMode.offline.shortLabel, "Offline")
        XCTAssertEqual(DiarizerMode.sortformer.shortLabel, "Sortformer")
        XCTAssertEqual(DiarizerMode.nemotron.shortLabel, "Nemotron 3")
    }

    /// The UI cap and the model's output slots must agree: a Stepper that
    /// offered more speakers than the checkpoint has slots would promise a
    /// count the model can never produce.
    func testNemotronSpeakerCapMatchesModelSlots() {
        XCTAssertEqual(DiarizerMode.nemotron.speakerCap, FluidDiarizer.nemotronConfig.numSpeakers)
        XCTAssertEqual(FluidDiarizer.nemotronTimelineConfig.numSpeakers, FluidDiarizer.nemotronConfig.numSpeakers)
    }

    /// Pins the preset so a change to it is a deliberate one: it decides the
    /// download (one ~200 MB bundle per preset) and the accuracy trade-off.
    func testNemotronUsesFast128Preset() {
        let config = FluidDiarizer.nemotronConfig
        XCTAssertEqual(config.modelFileName, "Nemotron3Diarizer_fast128.mlmodelc")
        XCTAssertEqual(config.chunkLen, 128)
        XCTAssertFalse(config.splitGraph)
    }

    func testNemotronTimelineConfigMatchesModelFrames() {
        let config = FluidDiarizer.nemotronTimelineConfig
        XCTAssertEqual(config.frameDurationSeconds, 0.01, accuracy: 1e-6)
        XCTAssertEqual(config.onsetThreshold, 0.5)
        XCTAssertEqual(config.offsetThreshold, 0.5)
        XCTAssertEqual(config.minFramesOn, 20, "speech shorter than 0.2 s is dropped")
        XCTAssertEqual(config.minFramesOff, 0)
    }

    /// Timeline → segments at Nemotron 3's frame rate: labels are the speaker
    /// slot (the key the post-hoc embeddings use), times come from the 10 ms
    /// grid, and a blip below the 0.2 s floor does not become a segment.
    func testSegmentsFromNemotronTimeline() throws {
        let speakers = FluidDiarizer.nemotronConfig.numSpeakers
        let frames = 400 // 4 s
        var predictions = [Float](repeating: 0, count: frames * speakers)
        func activate(slot: Int, _ range: Range<Int>) {
            for frame in range {
                predictions[frame * speakers + slot] = 0.9
            }
        }
        activate(slot: 0, 0 ..< 150) // 0.0 – 1.5 s
        activate(slot: 3, 160 ..< 170) // 0.1 s blip, below the floor
        activate(slot: 7, 200 ..< 400) // 2.0 – 4.0 s

        let timeline = try DiarizerTimeline(
            allPredictions: predictions, config: FluidDiarizer.nemotronTimelineConfig,
        )
        let segments = FluidDiarizer.segments(from: timeline).sorted { $0.start < $1.start }

        XCTAssertEqual(segments.map(\.speaker), ["SPEAKER_0", "SPEAKER_7"])
        XCTAssertEqual(segments[0].start, 0, accuracy: 1e-3)
        XCTAssertEqual(segments[0].end, 1.5, accuracy: 1e-3)
        XCTAssertEqual(segments[1].start, 2.0, accuracy: 1e-3)
        XCTAssertEqual(segments[1].end, 4.0, accuracy: 1e-3)
    }

    // MARK: - Load seam

    /// An unreadable file fails before the model is asked for, so a first run
    /// does not start a ~200 MB download it cannot use, and Nemotron 3 mode
    /// never reaches the offline clustering processor.
    func testUnreadableFileFailsBeforeModelLoad() async {
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let offlineCalls = OSAllocatedUnfairLock(initialState: 0)
        var offline = MockOfflineProcessor()
        offline.onProcess = { _ in
            offlineCalls.withLock { $0 += 1 }
            return MeetingTranscriber.DiarizationResult(segments: [], speakingTimes: [:], autoNames: [:], embeddings: nil)
        }
        let load: NemotronLoader = { units in
            loads.withLock { $0 += 1 }
            return (StubNemotronStream(), units)
        }
        let diarizer = FluidDiarizer(mode: .nemotron, offlineProcessor: offline, makeNemotronDiarizer: load)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemotron-missing-\(UUID().uuidString).wav")

        do {
            _ = try await diarizer.run(audioPath: missing, numSpeakers: 3, meetingTitle: "Test")
            XCTFail("Expected an unreadable file to throw")
        } catch {
            XCTAssertFalse(error is StubNemotronStream.Reached, "The run must stop at the audio, before streaming")
        }
        XCTAssertEqual(loads.withLock { $0 }, 0, "The model must not be loaded for a file that cannot be read")
        XCTAssertEqual(offlineCalls.withLock { $0 }, 0, "Nemotron 3 mode must not route through the offline processor")
    }

    /// A readable file loads the model once and streams through it; a second
    /// run on the same instance reuses the loaded model. The stub ends each
    /// run at the end of the stream, before the WeSpeaker embedding pass,
    /// which would need its own model download.
    func testReadableFileLoadsModelOnceAndReusesIt() async throws {
        let audio = try makeSilentWav()
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let stream = StubNemotronStream()
        let load: NemotronLoader = { units in
            loads.withLock { $0 += 1 }
            return (stream, units)
        }
        let diarizer = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)

        for run in 1 ... 2 {
            await Self.runExpectingStreamEnd(diarizer, audio: audio)
            XCTAssertEqual(loads.withLock { $0 }, 1, "Run \(run): one load for the first run, none after it")
        }
        XCTAssertEqual(stream.resets, 2, "Every run starts a fresh stream")
        XCTAssertEqual(stream.appendedSamples, 2 * 16000, "Both runs feed the whole second of audio")
    }

    /// The Nemotron 3 load must ask FluidAudio for CPU + Neural Engine
    /// explicitly. Passing nothing leaves `Nemotron3Models.loadFromHuggingFace`
    /// at its default `.all`, which lets Core ML route parts of the graph
    /// through the GPU.
    ///
    /// What this pins: `runNemotron` hands `.cpuAndNeuralEngine` to the load
    /// seam. What it does not: the stub replaces the default loader, so the
    /// forwarding from there into `Nemotron3Models.loadFromHuggingFace`
    /// (`FluidDiarizer+NemotronModelLoad.swift`) never runs here. That
    /// handoff is pinned by
    /// `FluidDiarizerQualityTests.test_nemotron_loadedModelRunsOnCpuAndNeuralEngine`,
    /// which needs the downloaded model and so runs only under
    /// `RUN_QUALITY_TESTS=1`.
    func testNemotronLoadRequestsCpuAndNeuralEngine() async throws {
        let audio = try makeSilentWav()
        let requested = OSAllocatedUnfairLock<[MLComputeUnits]>(initialState: [])
        let load: NemotronLoader = { units in
            requested.withLock { $0.append(units) }
            return (StubNemotronStream(), units)
        }
        let diarizer = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)

        _ = try? await diarizer.run(audioPath: audio, numSpeakers: nil, meetingTitle: "compute-units")

        XCTAssertEqual(requested.withLock { $0 }, [.cpuAndNeuralEngine])
    }

    /// A cancelled job must not ask for the model: on a first run the load is
    /// a ~200 MB download, and a job cancelled while it waited behind another
    /// instance's load would otherwise start one for nobody. The task cancels
    /// itself before `run`, so the outcome does not depend on scheduling.
    func testCancelledRunNeverCallsTheLoader() async throws {
        let audio = try makeSilentWav()
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let load: NemotronLoader = { units in
            loads.withLock { $0 += 1 }
            return (StubNemotronStream(), units)
        }
        let diarizer = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await diarizer.run(audioPath: audio, numSpeakers: nil, meetingTitle: "cancelled")
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }
        XCTAssertEqual(loads.withLock { $0 }, 0, "A cancelled run must not load the model")
    }

    // MARK: - Streaming

    /// A recording longer than one feed step reaches the model in
    /// `nemotronFeedSamples` pieces (60 s) plus the remainder, never as one
    /// block: the streaming front end is chosen so the mel spectrogram of the
    /// whole file is never held at once.
    func testLongRecordingIsFedInSixtySecondPieces() async throws {
        let audio = try makeSilentWav(seconds: 61)
        let stream = StubNemotronStream()
        let load: NemotronLoader = { units in (stream, units) }
        let diarizer = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)

        await Self.runExpectingStreamEnd(diarizer, audio: audio)

        XCTAssertEqual(stream.appendSizes, [FluidDiarizer.nemotronFeedSamples, 16000])
    }

    /// Cancelling a job mid-stream stops it before the next piece: a long
    /// recording does not keep the Neural Engine busy for a job nobody waits
    /// for. The stub cancels the run's own task while the first piece is
    /// being processed, so the outcome does not depend on scheduling.
    func testCancellationBetweenPiecesStopsTheStream() async throws {
        let audio = try makeSilentWav(seconds: 61)
        let stream = StubNemotronStream()
        stream.onProcess = { withUnsafeCurrentTask { $0?.cancel() } }
        let load: NemotronLoader = { units in (stream, units) }
        let diarizer = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)

        do {
            _ = try await diarizer.run(audioPath: audio, numSpeakers: nil, meetingTitle: "cancelled mid-stream")
            XCTFail("A run cancelled mid-stream must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }
        XCTAssertEqual(stream.appendSizes, [FluidDiarizer.nemotronFeedSamples], "No piece may follow the cancellation")
    }

    // MARK: - Concurrency

    /// Nemotron 3 mode serialises its own runs (see `DiarizationProvider`),
    /// and `Nemotron3Diarizer` carries stream state and is not thread-safe.
    /// Two runs on one instance must therefore never stream at the same
    /// time. The probe holds the first run inside its stream for up
    /// to half a second, waiting for the second run to arrive: without
    /// serialisation the second run does arrive, and the probe sees two at
    /// once.
    func testConcurrentRunsOnOneInstanceDoNotStreamAtTheSameTime() async throws {
        let audio = try makeSilentWav()
        let probe = OverlapProbe()
        let stream = StubNemotronStream()
        stream.onProcess = { probe.holdUntilOverlapOrTimeout(seconds: 0.5) }
        let load: NemotronLoader = { units in (stream, units) }
        let diarizer = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)

        async let first: Void = Self.runExpectingStreamEnd(diarizer, audio: audio)
        async let second: Void = Self.runExpectingStreamEnd(diarizer, audio: audio)
        _ = await (first, second)

        XCTAssertEqual(probe.entries, 2, "Both runs must reach the stream")
        XCTAssertEqual(probe.maxConcurrent, 1, "Two runs streamed through the same diarizer at once")
        XCTAssertEqual(stream.resets, 2)
    }

    /// Every pipeline job, speaker-naming re-run and voice enrollment builds
    /// its own `FluidDiarizer`, so two instances can start the first-time
    /// model download together. FluidAudio deletes a model folder that has no
    /// version marker yet, and writes the marker only once a download is
    /// complete, so the second load would delete the first one's half-written
    /// download. Loads must therefore not overlap even across instances.
    func testModelLoadsDoNotOverlapAcrossInstances() async throws {
        let audio = try makeSilentWav()
        let probe = OverlapProbe()
        let load: NemotronLoader = { units in
            probe.holdUntilOverlapOrTimeout(seconds: 0.5)
            return (StubNemotronStream(), units)
        }
        let pipelineJob = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)
        let namingRerun = FluidDiarizer(mode: .nemotron, makeNemotronDiarizer: load)

        async let first: Void = Self.runExpectingStreamEnd(pipelineJob, audio: audio)
        async let second: Void = Self.runExpectingStreamEnd(namingRerun, audio: audio)
        _ = await (first, second)

        XCTAssertEqual(probe.entries, 2, "Each instance loads its own model")
        XCTAssertEqual(probe.maxConcurrent, 1, "Two instances loaded the model at once")
    }

    // MARK: - Helpers

    private static func runExpectingStreamEnd(_ diarizer: FluidDiarizer, audio: URL) async {
        do {
            _ = try await diarizer.run(audioPath: audio, numSpeakers: nil, meetingTitle: "Test")
            XCTFail("The stub ends every run at the end of the stream")
        } catch {
            XCTAssertTrue(error is StubNemotronStream.Reached, "Expected the stream end, got \(error)")
        }
    }

    /// `seconds` of 16 kHz mono silence in a temporary WAV file, removed
    /// at teardown.
    private func makeSilentWav(seconds: Int = 1) throws -> URL {
        let url = makeTempFile(suffix: ".wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0, count: seconds * 16000), sampleRate: 16000, url: url)
        return url
    }
}

/// Records how many callers are inside at once. `holdUntilOverlapOrTimeout`
/// blocks its caller until a second caller is inside too or the timeout
/// passes, so an overlap that the code under test allows is forced to
/// happen instead of depending on scheduling luck.
private final class OverlapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var peak = 0
    private var entered = 0

    var maxConcurrent: Int {
        lock.withLock { peak }
    }

    var entries: Int {
        lock.withLock { entered }
    }

    func holdUntilOverlapOrTimeout(seconds: TimeInterval) {
        lock.withLock {
            inside += 1
            entered += 1
            peak = max(peak, inside)
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, maxConcurrent < 2 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        lock.withLock { inside -= 1 }
    }
}

/// Streaming stand-in with no model: records what the production loop feeds
/// it and ends the stream by throwing `Reached`, which stops a run before the
/// embedding pass.
private final class StubNemotronStream: NemotronStreamingDiarizing, @unchecked Sendable {
    struct Reached: Error {}

    private let lock = NSLock()
    private var resetCount = 0
    private var sizes: [Int] = []
    /// Runs inside `processBufferedAudio`, for tests that need to hold a run
    /// in the middle of its stream.
    var onProcess: (@Sendable () -> Void)?

    var resets: Int {
        lock.withLock { resetCount }
    }

    var appendedSamples: Int {
        appendSizes.reduce(0, +)
    }

    /// Sample count of every `appendAudio` call, in order.
    var appendSizes: [Int] {
        lock.withLock { sizes }
    }

    func reset() {
        lock.withLock { resetCount += 1 }
    }

    func appendAudio(_ samples: [Float]) {
        lock.withLock { sizes.append(samples.count) }
    }

    func processBufferedAudio() -> [Nemotron3ChunkResult] {
        onProcess?()
        return []
    }

    func finishStream() throws -> [Nemotron3ChunkResult] {
        throw Reached()
    }
}
