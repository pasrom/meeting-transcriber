import enum FluidAudio.ASRError
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
/// is told to refuse the empty track exactly as the real one does. Since a
/// `.both` pair now also survives a track the engine refuses, a surviving job
/// alone no longer proves the guard ran: the tests that pin it also assert the
/// empty track never reached the engine, and that the warning names the empty
/// track rather than a failed transcription.
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
        XCTAssertEqual(h.engine.transcribeCallCount, 1, "the empty track must not reach the engine")
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
        XCTAssertTrue(warnings.lowercased().contains("microphone track carried nothing"), "got: \(warnings)")
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
        XCTAssertTrue(text.lowercased().contains("nothing from the microphone track"), "got: \(text.prefix(200))")
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
        XCTAssertTrue(text.lowercased().contains("nothing from the app-audio track"), "got: \(text.prefix(200))")
        XCTAssertEqual(h.engine.transcribeCallCount, 1, "the empty track must not reach the engine")
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

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
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

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 0, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(
            h.queue.jobs.first?.state, .error,
            "a transcript that is only the recording note is not a transcript",
        )
    }

    // MARK: - A track that fails in the engine

    /// The frame count cannot see a decode failure: both tracks carry audio,
    /// pass the viability check, and the microphone still fails in the
    /// engine. The intact far end must survive that just as it survives an
    /// empty microphone file.
    func testAMicTrackThatFailsToTranscribeKeepsTheAppTranscript() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.state, .done, "error: \(job.error ?? "none")")
        XCTAssertTrue(try transcript(h).contains("far end speaking"))
        let warnings = job.warnings.joined(separator: " | ")
        XCTAssertTrue(warnings.contains("microphone track could not be transcribed"), "got: \(warnings)")
        XCTAssertTrue(warnings.contains("Must be at least 300ms"), "the engine's reason is lost: \(warnings)")
    }

    func testAnAppTrackThatFailsToTranscribeKeepsTheMicTranscript() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["app_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.state, .done, "error: \(job.error ?? "none")")
        XCTAssertTrue(try transcript(h).contains("local answer"))
        XCTAssertTrue(job.warnings.joined().contains("app-audio track could not be transcribed"))
    }

    func testBothTracksFailingToTranscribeFailsWithTheEnginesMessage() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["app_16k.wav", "mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.state, .error)
        XCTAssertEqual(job.error, ASRError.invalidAudioData.localizedDescription)
    }

    /// The dropped track downgrades the stored verdict, so the transcript
    /// carries the same note an empty track gets: without it the protocol
    /// model is handed half a meeting that reads as a whole one.
    func testATrackThatFailsToTranscribeDowngradesTheVerdictAndNotesIt() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(h.queue.jobs.first?.trackViability, .appOnly)
        let text = try transcript(h)
        XCTAssertTrue(text.hasPrefix("[Recording note:"), "got: \(text.prefix(120))")
        XCTAssertFalse(text.contains("carried nothing"), "a failed track is not an empty one")
    }

    /// Neither the first diarization nor the late re-run may diarize the
    /// failed track: its speakers would have no text, and their embeddings
    /// would be confirmed from audio nobody transcribed.
    func testATrackThatFailsToTranscribeIsNotDiarizedNowOrLater() async throws {
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
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        XCTAssertEqual(namingCalls, 2, "the rerun has to actually run")
        let diarized = h.diarization.receivedAudioPaths.map(\.lastPathComponent)
        XCTAssertEqual(diarized.count, 2, "one app run, one late re-run, got: \(diarized)")
        XCTAssertFalse(diarized.contains { $0.contains("mic") }, "the failed track was diarized: \(diarized)")
    }

    /// A failure next to a track that transcribed to nothing is the job's
    /// explanation. Reporting "Empty transcript" would hide it.
    func testAFailureNextToAnEmptyTrackIsTheJobError() async throws {
        let h = makeHarness()
        h.engine.throwingPathSuffixes = ["mic_16k.wav"]
        h.engine.segmentsByPathSuffix = ["app_16k.wav": []]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.state, .error)
        XCTAssertEqual(job.error, ASRError.invalidAudioData.localizedDescription)
    }

    /// A model that cannot load fails on any file. It ends the job as an
    /// error the user can retry, and the second track is not sent to load
    /// the same model again.
    func testAnEngineWideFailureEndsTheJobWithoutTryingTheSecondTrack() async throws {
        let h = makeHarness()
        h.engine.shouldThrow = true

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.state, .error)
        XCTAssertEqual(job.error, "Mock transcription error")
        XCTAssertEqual(h.engine.transcribeCallCount, 1, "the microphone track was still sent to the engine")
        XCTAssertEqual(job.trackViability, .both, "an engine failure is not a dropped track")
    }

    /// Even with the app track transcribed, an engine-wide failure on the
    /// microphone ends the job: saving the far end alone as a finished job
    /// would hide a model fault behind half a transcript.
    func testAnEngineWideFailureOnTheSecondTrackIsNotADroppedTrack() async throws {
        let h = makeHarness()
        h.engine.modelFailurePathSuffixes = ["mic_16k.wav"]

        try await run(
            h,
            app: writeTrack(frames: 160_000, named: "meeting_app.wav"),
            mic: writeTrack(frames: 160_000, named: "meeting_mic.wav"),
        )

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.state, .error)
        XCTAssertEqual(job.error, ASRError.modelLoadFailed.localizedDescription)
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
        XCTAssertEqual(
            h.engine.transcribeCallCount, 1,
            "the first refusal is the job's error; the second file is not decoded just to repeat it",
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
