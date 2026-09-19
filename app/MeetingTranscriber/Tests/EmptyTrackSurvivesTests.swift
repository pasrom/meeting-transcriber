@testable import MeetingTranscriber
import XCTest

/// A dual-source recording with one empty track still produces a transcript.
///
/// The field artifact this is built from: `_mic.wav`, 4096 bytes on disk, zero
/// audio packets, next to an app track holding the whole meeting. Three
/// recordings in issue #724 ended as a failed job with no transcript at all,
/// and the recording was marked processed, so nothing picked it up again.
///
/// Driven through `enqueue` + `processNext`, not by calling the stage, because
/// what failed was the job and what has to survive is the job. The mock engine
/// is told to refuse the empty track exactly as the real one does: that is what
/// makes these tests falsify the fix rather than the mock. Remove the guard and
/// the refusal comes back out of the queue.
@MainActor
final class EmptyTrackSurvivesTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // The shared helper, which registers its own teardown. Removing the
        // directory by hand fails here: the pipeline writes the transcript
        // owner-only, and a tearDown that throws on that turns every real
        // assertion into a second, misleading failure.
        tmpDir = try makeTempDirectory(prefix: "emptytrack")
    }

    // MARK: - Harness

    private struct Harness {
        let queue: PipelineQueue
        let engine: MockEngine
    }

    private func makeHarness(diarizeEnabled: Bool = false) -> Harness {
        let engine = MockEngine()
        engine.segmentsByPathSuffix = [
            "app_16k.wav": [TimestampedSegment(start: 0, end: 5, text: "far end speaking")],
            "mic_16k.wav": [TimestampedSegment(start: 6, end: 9, text: "local answer")],
        ]
        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 5.0],
            autoNames: [:],
            embeddings: ["SPEAKER_00": [1, 0, 0]],
        )
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            diarizeEnabled: diarizeEnabled,
            echoDedupEnabled: false,
        )
        return Harness(queue: queue, engine: engine)
    }

    /// The whole recording, as the recorder leaves it. `frames: 0` writes the
    /// field artifact: a readable WAV whose header is all there is.
    private func writeTrack(frames: Int, named name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.05, count: frames),
            sampleRate: AudioConstants.targetSampleRate,
            url: url,
        )
        return url
    }

    private func run(_ h: Harness, app: URL, mic: URL) async {
        h.queue.speakerNamingHandler = { _ in .skipped }
        h.queue.enqueue(PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil, appPath: app, micPath: mic, micDelay: 0,
        ))
        await h.queue.processNext()
        for _ in 0 ..< 200 where !(h.queue.jobs.first?.state.isTerminal ?? true) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func transcript(_ h: Harness) throws -> String {
        let path = try XCTUnwrap(h.queue.jobs.first?.transcriptPath)
        return try String(contentsOf: path, encoding: .utf8)
    }

    // MARK: - The recording that was lost

    func testAnEmptyMicTrackNoLongerFailsTheJob() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        await run(
            h,
            app: try writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done, "error: \(h.queue.jobs.first?.error ?? "none")")
        XCTAssertTrue(try transcript(h).contains("far end speaking"), "the intact track has to reach the transcript")
    }

    func testTheDroppedMicTrackIsReportedOnTheJob() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        await run(
            h,
            app: try writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        let warnings = (h.queue.jobs.first?.warnings ?? []).joined(separator: " | ")
        XCTAssertTrue(warnings.lowercased().contains("microphone track"), "got: \(warnings)")
    }

    /// The transcript is the artifact that outlives the job, and the text the
    /// protocol model is handed. Without the note a half recording is
    /// indistinguishable from a meeting the user only listened to.
    func testTheTranscriptSaysTheMicTrackWasEmpty() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        await run(
            h,
            app: try writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        let text = try transcript(h)
        XCTAssertTrue(text.hasPrefix("[Recording note:"), "got: \(text.prefix(120))")
        XCTAssertTrue(text.lowercased().contains("microphone track was empty"), "got: \(text.prefix(200))")
    }

    /// Diarization replaces the transcript with its speaker-labeled rendering,
    /// which is where a note prepended at the transcription stage disappears.
    func testTheNoteSurvivesTheSpeakerLabelledRewrite() async throws {
        let h = makeHarness(diarizeEnabled: true)
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        await run(
            h,
            app: try writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        let text = try transcript(h)
        XCTAssertTrue(text.hasPrefix("[Recording note:"), "got: \(text.prefix(120))")
    }

    // MARK: - The mirror case

    func testAnEmptyAppTrackKeepsTheMicrophoneTranscript() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["app_16k.wav"]

        await run(
            h,
            app: try writeTrack(frames: 0, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done, "error: \(h.queue.jobs.first?.error ?? "none")")
        let text = try transcript(h)
        XCTAssertTrue(text.contains("local answer"), "got: \(text)")
        XCTAssertTrue(text.lowercased().contains("app-audio track was empty"), "got: \(text.prefix(200))")
    }

    // MARK: - What must not change

    func testBothTracksEmptyStillFailsTheJob() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["app_16k.wav", "mic_16k.wav"]

        await run(
            h,
            app: try writeTrack(frames: 0, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(
            h.queue.jobs.first?.state, .error,
            "with nothing on either side there is no transcript to save",
        )
    }

    func testAHealthyRecordingIsNeitherWarnedAboutNorAnnotated() async throws {
        let h = makeHarness()

        await run(
            h,
            app: try writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertEqual(h.queue.jobs.first?.warnings ?? [], [])
        XCTAssertFalse(try transcript(h).contains("Recording note"))
    }
}
