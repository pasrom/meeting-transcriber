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
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
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
        let diarization: MockDiarization
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
        return Harness(queue: queue, engine: engine, diarization: diarization)
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

    /// `naming` is a parameter because the late-re-diarization test needs a
    /// handler that reruns once; every other test skips naming.
    private func run(
        _ h: Harness,
        naming: @escaping (PipelineQueue.SpeakerNamingData) async -> PipelineQueue.SpeakerNamingResult = { _ in .skipped },
        app: URL, mic: URL,
    ) async {
        h.queue.speakerNamingHandler = naming
        h.queue.enqueue(PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil, appPath: app, micPath: mic, micDelay: 0,
        ))
        await h.queue.processNext()
        // The suite's shared helper rather than a hand-rolled loop: the naming
        // path lands just after `processNext` returns, so a 50 ms tick is paid
        // in full for nothing.
        await waitFor(h.queue.jobs.first?.state.isTerminal ?? false, timeout: .seconds(10))
    }

    private func transcript(_ h: Harness) throws -> String {
        let path = try XCTUnwrap(h.queue.jobs.first?.transcriptPath)
        return try String(contentsOf: path, encoding: .utf8)
    }

    // MARK: - The recording that was lost

    func testAnEmptyMicTrackNoLongerFailsTheJob() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done, "error: \(h.queue.jobs.first?.error ?? "none")")
        XCTAssertTrue(try transcript(h).contains("far end speaking"), "the intact track has to reach the transcript")
    }

    func testTheDroppedMicTrackIsReportedOnTheJob() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
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

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        let text = try transcript(h)
        XCTAssertTrue(text.hasPrefix("[Recording note:"), "got: \(text.prefix(120))")
        XCTAssertTrue(text.lowercased().contains("microphone track carried nothing"), "got: \(text.prefix(200))")
    }

    /// Diarization replaces the transcript with its speaker-labeled rendering,
    /// which is where a note prepended at the transcription stage disappears.
    func testTheNoteSurvivesTheSpeakerLabelledRewrite() async throws {
        let h = makeHarness(diarizeEnabled: true)
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        let text = try transcript(h)
        XCTAssertTrue(text.hasPrefix("[Recording note:"), "got: \(text.prefix(120))")
    }

    /// The late re-diarization renders the transcript again from the cached
    /// segments and writes that over the saved file. Those segments never
    /// carried the note, so without carrying it over explicitly a re-run after
    /// the meeting silently drops the one line saying a track is missing.
    func testTheNoteSurvivesALateRediarization() async throws {
        let h = makeHarness(diarizeEnabled: true)
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]
        var namingCalls = 0

        try await run(
            h,
            naming: { _ in
                namingCalls += 1
                return namingCalls == 1 ? .rerun(2) : .skipped
            },
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(namingCalls, 2, "the rerun has to actually run the late rewrite")
        let text = try transcript(h)
        XCTAssertTrue(text.hasPrefix("[Recording note:"), "got: \(text.prefix(120))")
    }

    /// The verdict is taken once and read by the stage after transcription too.
    /// Without that the empty track was still handed to the diarizer, which
    /// then failed on it and added a second warning for one cause, naming the
    /// wrong one: nothing failed to diarize, there was nothing to diarize.
    func testAnEmptyTrackIsNotOfferedToTheDiarizer() async throws {
        let h = makeHarness(diarizeEnabled: true)
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(
            h.diarization.runCount, 1,
            "the app track only; a file already measured as empty must not reach a model",
        )
    }

    func testTheEmptyTrackIsReportedOnceAndNotAsADiarizationFailure() async throws {
        let h = makeHarness(diarizeEnabled: true)
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        let warnings = h.queue.jobs.first?.warnings ?? []
        XCTAssertEqual(warnings.count, 1, "one cause, one warning, got: \(warnings)")
        XCTAssertFalse(
            warnings[0].lowercased().contains("diarization failed"),
            "got: \(warnings[0])",
        )
    }

    // MARK: - The mirror case

    func testAnEmptyAppTrackKeepsTheMicrophoneTranscript() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["app_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 0, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done, "error: \(h.queue.jobs.first?.error ?? "none")")
        let text = try transcript(h)
        XCTAssertTrue(text.contains("local answer"), "got: \(text)")
        XCTAssertTrue(text.lowercased().contains("app-audio track carried nothing"), "got: \(text.prefix(200))")
    }

    // MARK: - A track that cannot even be read

    /// The resample runs before the verdict, so a source that throws there used
    /// to end the job before anything could decide the other track was fine.
    /// `frameCount` folding "unreadable" into "empty" was unreachable for
    /// exactly the inputs it names.
    func testAMicTrackThatCannotBeResampledKeepsTheAppTranscript() async throws {
        let h = makeHarness()
        let corrupt = tmpDir.appendingPathComponent("meeting_mic.wav")
        try Data("not audio at all".utf8).write(to: corrupt)

        await run(
            h,
            app: try writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: corrupt,
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done, "error: \(h.queue.jobs.first?.error ?? "none")")
        XCTAssertTrue(try transcript(h).contains("far end speaking"))
    }

    // MARK: - The note must not stand in for a transcript

    /// A dropped track renders its note even when the surviving track produces
    /// no segments. The empty-transcript guard reads a string, so the note
    /// alone satisfied it and the job was saved as a success carrying one
    /// sentence, with a protocol generated from it.
    func testANoteAloneIsNotATranscript() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]
        h.engine.segmentsByPathSuffix = ["app_16k.wav": []]

        await run(
            h,
            app: try writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: try writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(
            h.queue.jobs.first?.state, .error,
            "a transcript that is only the recording note is not a transcript",
        )
    }

    // MARK: - What must not change

    func testBothTracksEmptyStillFailsTheJob() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["app_16k.wav", "mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 0, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(
            h.queue.jobs.first?.state, .error,
            "with nothing on either side there is no transcript to save",
        )
    }

    /// Nil has to keep meaning "no verdict was taken". A healthy dual-source
    /// recording records `.both`, so a reader can tell it apart from a job the
    /// check never ran for.
    func testAHealthyRecordingStillRecordsItsVerdict() async throws {
        let h = makeHarness()

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.trackViability, .both)
    }

    func testAHealthyRecordingIsNeitherWarnedAboutNorAnnotated() async throws {
        let h = makeHarness()

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertEqual(h.queue.jobs.first?.warnings ?? [], [])
        XCTAssertFalse(try transcript(h).contains("Recording note"))
    }
}
