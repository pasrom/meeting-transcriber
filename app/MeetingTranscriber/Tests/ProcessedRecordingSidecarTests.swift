import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The recording sidecar (`<stem>_recording.json`) of a dual-source recording
/// the pipeline processes: written when the recording is enqueued and read back
/// by a re-import. Never `_meta.json`, which a record-only consumer of the
/// recordings folder takes as a recording waiting for it. Its moves with the
/// tracks are pinned where those moves are tested (`PipelineQueueRetentionTests`,
/// `CancelledJobWritesNothingTests`, `PipelineQueueTests`).
@MainActor
final class ProcessedRecordingSidecarTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "processed-recording-sidecar")
    }

    /// A controller whose queue writes into `tmpDir` and treats `staging` as
    /// the recorder's folder.
    private func makeController(engine: MockEngine = MockEngine(), staging: URL? = nil) throws -> PipelineController {
        try makeIsolatedPipelineController(initialQueue: PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() }, outputDir: tmpDir, logDir: tmpDir,
            stagingDir: staging ?? tmpDir.appendingPathComponent("staging"),
            diarizeEnabled: false, echoDedupEnabled: false,
        ))
    }

    private func touch(_ names: [String]) -> [URL] {
        names.map { name in
            let url = tmpDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("RIFF".utf8))
            return url
        }
    }

    // MARK: - Writing

    /// A dual-source recording keeps its mic offset and mute times beside its
    /// tracks, under the recording sidecar's name and not `_meta.json`.
    func testADualSourceRecordingGetsARecordingSidecar() async throws {
        let queue = try makeIsolatedQueue()
        let urls = touch(["20260503_120000_mix.wav", "20260503_120000_app.wav", "20260503_120000_mic.wav"])
        let (loop, recorder) = makeTestWatchLoop(pipelineQueue: queue)
        (recorder.mixPath, recorder.appPath, recorder.micPath) = (urls[0], urls[1], urls[2])
        recorder.micDelay = 0.25
        recorder.micMuteIntervals = [MicMuteInterval(start: 1, end: 2)]

        try await loop.startManualRecording(pid: 42, appName: "Microsoft Teams", title: "Standup")
        await loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.count, 1)
        let sidecar = try XCTUnwrap(
            RecordingSidecar.read(from: tmpDir.appendingPathComponent("20260503_120000_recording.json")),
            "no recording sidecar beside the mix",
        )
        XCTAssertEqual(sidecar.micDelaySeconds, 0.25)
        XCTAssertEqual(sidecar.micMuteIntervals, [MicMuteInterval(start: 1, end: 2)])
        XCTAssertEqual(sidecar.title, "Standup")
        XCTAssertEqual(sidecar.trigger, .manual)
        XCTAssertEqual(sidecar.files.app, "20260503_120000_app.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("20260503_120000_meta.json").path))
    }

    /// One track has no offset to keep.
    func testASingleSourceRecordingGetsNone() async throws {
        let queue = try makeIsolatedQueue()
        let urls = touch(["20260503_120000_mix.wav", "20260503_120000_mic.wav"])
        let (loop, recorder) = makeTestWatchLoop(pipelineQueue: queue)
        (recorder.mixPath, recorder.micPath) = (urls[0], urls[1])

        try await loop.startManualRecording(pid: 42, appName: "Microsoft Teams", title: "Standup")
        await loop.stopManualRecording()

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).sorted(), [
            "20260503_120000_mic.wav", "20260503_120000_mix.wav",
        ])
    }

    // MARK: - Re-import

    /// A re-import reads the recording sidecar, so a microphone that started
    /// after the app tap keeps its offset and the mute times their place,
    /// instead of both falling back to none.
    func testAReimportReadsTheRecordingSidecar() throws {
        let controller = try makeController()
        let names = ["call_mix.wav", "call_app.wav", "call_mic.wav"]
        let urls = touch(names)
        let muted = [MicMuteInterval(start: 2, end: 4)]
        try RecordingSidecar(
            title: "Weekly Sync", appName: "Teams", startedAt: Date(), stoppedAt: Date(),
            participants: ["Speaker A"], micDelaySeconds: 0.25, trigger: .auto,
            mixFilename: names[0], appFilename: names[1], micFilename: names[2], micMuteIntervals: muted,
        ).write(to: tmpDir.appendingPathComponent("call" + RecordingSidecar.recordingFilenameSuffix))

        controller.enqueueExistingFiles(urls)

        let job = try XCTUnwrap(controller.queue.jobs.first)
        XCTAssertEqual(job.micDelay, 0.25, "the recorded mic offset was not picked up")
        XCTAssertEqual(job.micMuteIntervals, muted)
        XCTAssertEqual(job.meetingTitle, "Weekly Sync")
        XCTAssertEqual(job.participants, ["Speaker A"])
    }

    /// A folder holding both reads the record-only sidecar: it is what an
    /// external consumer was handed, so it is the one that describes the files.
    func testAReimportPrefersTheRecordOnlySidecar() throws {
        let controller = try makeController()
        let urls = touch(["call_app.wav", "call_mic.wav"])
        for (suffix, delay) in [(RecordingSidecar.filenameSuffix, 0.5), (RecordingSidecar.recordingFilenameSuffix, 0.25)] {
            try RecordingSidecar(
                title: "t", appName: "Teams", startedAt: Date(), stoppedAt: Date(),
                participants: [], micDelaySeconds: delay, trigger: .auto,
                mixFilename: "call_mix.wav", appFilename: "call_app.wav", micFilename: "call_mic.wav",
            ).write(to: tmpDir.appendingPathComponent("call" + suffix))
        }

        controller.enqueueExistingFiles(urls)

        XCTAssertEqual(try XCTUnwrap(controller.queue.jobs.first).micDelay, 0.5)
    }

    /// The whole way round: recorded with a microphone that started after the
    /// app tap (a positive offset, which the recorder reports as it is),
    /// processed, and its relocated tracks imported again. The re-import has to
    /// align the tracks and place the mutes as the first run did, not take the
    /// offset as zero.
    func testAReimportOfAProcessedRecordingKeepsItsMicOffsetAndMutes() async throws {
        let staging = tmpDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 11, end: 13, text: "far end speaking")]
        let controller = try makeController(engine: engine, staging: staging)
        let tracks = [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic]
            .map { staging.appendingPathComponent("20260503_120000" + $0) }
        for url in tracks {
            try AudioMixer.saveWAV(
                samples: [Float](repeating: 0.05, count: 30 * AudioConstants.targetSampleRate),
                sampleRate: AudioConstants.targetSampleRate, url: url,
            )
        }
        let (loop, recorder) = makeTestWatchLoop(pipelineQueue: controller.queue)
        (recorder.mixPath, recorder.appPath, recorder.micPath) = (tracks[0], tracks[1], tracks[2])
        recorder.micDelay = 0.25
        recorder.micMuteIntervals = [MicMuteInterval(start: 2, end: 4)]
        try await loop.startManualRecording(pid: 42, appName: "Microsoft Teams", title: "Standup")
        await loop.stopManualRecording()
        // The enqueue started the queue's own run, so wait for that one: a
        // `processNext()` here can find the job already running and return.
        await controller.queue.awaitProcessing()
        let first = try XCTUnwrap(controller.queue.jobs.first)
        let relocated = try [XCTUnwrap(first.mixPath), XCTUnwrap(first.appPath), XCTUnwrap(first.micPath)]
        XCTAssertTrue(
            relocated.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "recordings" },
            "test premise: the tracks left staging",
        )

        let id = try XCTUnwrap(controller.enqueueFiles(relocated).first)

        let reimported = try XCTUnwrap(controller.queue.jobs.first { $0.id == id })
        XCTAssertEqual(reimported.micDelay, 0.25, "the re-import lost the recorded mic offset")
        XCTAssertEqual(reimported.micMuteIntervals, [MicMuteInterval(start: 2, end: 4)])
        XCTAssertEqual(reimported.micMuteSpansOnTranscript, first.micMuteSpansOnTranscript, "the mutes moved")
        XCTAssertEqual(reimported.meetingTitle, "Standup")
    }
}
