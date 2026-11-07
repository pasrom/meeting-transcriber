import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Driven through `enqueue` + `processNext`, because what mute times must change
/// is the saved transcript and the job's outcome.
@MainActor
final class MicMutePipelineIntegrationTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "micmute")
    }

    private func track(_ name: String, seconds: Int = 30) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.05, count: seconds * AudioConstants.targetSampleRate),
            sampleRate: AudioConstants.targetSampleRate,
            url: url,
        )
        return url
    }

    private func run(_ job: PipelineJob, engine: MockEngine) async throws -> (job: PipelineJob?, transcript: String?) {
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            diarizeEnabled: false,
            echoDedupEnabled: false,
        )
        queue.enqueue(job)
        await queue.processNext()
        let finished = queue.job(withID: job.id)
        let transcript = try finished?.transcriptPath.map { try String(contentsOf: $0, encoding: .utf8) }
        return (finished, transcript)
    }

    private func dualEngine() -> MockEngine {
        let engine = MockEngine()
        engine.segmentsByPathSuffix = [
            "app_16k.wav": [TimestampedSegment(start: 0, end: 5, text: "far end speaking")],
            "mic_16k.wav": [
                TimestampedSegment(start: 6, end: 9, text: "local answer"),
                TimestampedSegment(start: 12, end: 15, text: "invented on silence"),
            ],
        ]
        return engine
    }

    func testPartialMuteDropsTheTextAndMarksTheTranscriptOnTheAppTimeline() async throws {
        let job = try PipelineJob(
            meetingTitle: "m", appName: "File", mixPath: nil,
            appPath: track("a.wav"), micPath: track("b.wav"), micDelay: 1,
            micMuteIntervals: [MicMuteInterval(start: 10, end: 20)],
        )
        let result = try await run(job, engine: dualEngine())
        let transcript = try XCTUnwrap(result.transcript)

        XCTAssertTrue(transcript.contains("local answer"))
        XCTAssertFalse(transcript.contains("invented on silence"))
        XCTAssertTrue(transcript.contains("[Mic muted 00:11–00:21]"))
        XCTAssertEqual(result.job?.trackViability, .both)
    }

    /// `[9, 11]` on the mic track is half inside `[10, 20]` and kept; shifted
    /// first it would be `[10, 12]`, wholly inside, and dropped.
    func testMuteTimesFilterOnTheMicTimelineBeforeTheShift() async throws {
        let engine = dualEngine()
        engine.segmentsByPathSuffix["mic_16k.wav"] = [TimestampedSegment(start: 9, end: 11, text: "straddling")]
        let job = try PipelineJob(
            meetingTitle: "m", appName: "File", mixPath: nil,
            appPath: track("a.wav"), micPath: track("b.wav"), micDelay: 1,
            micMuteIntervals: [MicMuteInterval(start: 10, end: 20)],
        )
        let result = try await run(job, engine: engine)
        let transcript = try XCTUnwrap(result.transcript)

        XCTAssertTrue(transcript.contains("straddling"))
    }

    func testOrphanRecoveryAttachesTheMuteLogAndConsumesIt() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let stem = "20260311_100000"
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.mic] {
            try FileManager.default.moveItem(at: track("\(stem)\(suffix)", seconds: 2), to: recDir.appendingPathComponent(stem + suffix))
        }
        var timeline = MicMuteTimeline()
        timeline.setMuted(true)
        MicMuteLog.write(timeline, stem: stem, in: recDir)

        let queue = PipelineQueue(logDir: tmpDir)
        await queue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertEqual(queue.jobs.first?.micMuteSpansOnTranscript, [MicMuteInterval(start: 0, end: 2)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recDir.appendingPathComponent(stem + RecordingFileSuffix.micMuteLog).path))
    }

    /// A finished stem the scan skips (here, one already processed) would keep its
    /// log forever: nothing else ever reads it again.
    func testOrphanRecoveryReapsTheMuteLogOfASkippedRecording() async throws {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let stem = "20260311_110000"
        let mix = recDir.appendingPathComponent(stem + RecordingFileSuffix.mix)
        try FileManager.default.moveItem(at: track("skipped_mix.wav", seconds: 1), to: mix)
        let mic = recDir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try FileManager.default.moveItem(at: track("skipped_mic.wav", seconds: 1), to: mic)
        MicMuteLog.write(MicMuteTimeline(), stem: stem, in: recDir)
        let processed = PipelineQueue(logDir: tmpDir)
        let job = PipelineJob(meetingTitle: "m", appName: "a", mixPath: mix, appPath: nil, micPath: nil, micDelay: 0)
        processed.insertJobForTesting(job)
        processed.updateJobState(id: job.id, to: .error, error: "Empty transcript")

        let queue = PipelineQueue(logDir: tmpDir)
        await queue.recoverOrphanedRecordings(recordingsDir: recDir)

        XCTAssertTrue(queue.jobs.isEmpty, "test premise: the recording was skipped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recDir.appendingPathComponent(stem + RecordingFileSuffix.micMuteLog).path))
    }

    func testMutedThroughoutSkipsTheMicWithoutAWarning() async throws {
        let engine = dualEngine()
        engine.throwingPathSuffixes = ["mic_16k.wav"]
        let job = try PipelineJob(
            meetingTitle: "m", appName: "File", mixPath: nil,
            appPath: track("a.wav"), micPath: track("b.wav"), micDelay: 0,
            micMuteIntervals: [MicMuteInterval(start: 0, end: 30)],
        )
        let result = try await run(job, engine: engine)
        let transcript = try XCTUnwrap(result.transcript)

        XCTAssertEqual(result.job?.trackViability, .appOnlyMicMuted)
        XCTAssertTrue(transcript.contains("far end speaking"))
        XCTAssertTrue(transcript.contains("muted for this whole recording"))
        XCTAssertEqual(result.job?.warnings, [])
    }

    func testMicrophoneOnlyMutedThroughoutFailsSayingWhy() async throws {
        let engine = MockEngine()
        engine.shouldThrow = true
        let job = try PipelineJob(
            meetingTitle: "m", appName: "Microphone", mixPath: track("m.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
            micMuteIntervals: [MicMuteInterval(start: 0, end: 30)],
        )
        let result = try await run(job, engine: engine)

        XCTAssertEqual(result.job?.state, .error)
        XCTAssertEqual(result.job?.error?.contains("muted for the whole recording"), true)
    }

    func testMicrophoneOnlyPartialMuteKeepsTheRest() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 1, end: 3, text: "kept"),
            TimestampedSegment(start: 11, end: 13, text: "invented"),
        ]
        let job = try PipelineJob(
            meetingTitle: "m", appName: "Microphone", mixPath: track("m.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
            micMuteIntervals: [MicMuteInterval(start: 10, end: 20)],
        )
        let result = try await run(job, engine: engine)
        let transcript = try XCTUnwrap(result.transcript)

        XCTAssertTrue(transcript.contains("kept"))
        XCTAssertFalse(transcript.contains("invented"))
        XCTAssertTrue(transcript.contains("[Mic muted 00:10–00:20]"))
    }
}
