import Foundation
@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// A WhisperKit failure reaches the caller as an error, not as an empty
/// transcript, and a cancelled decode as `CancellationError`.
@MainActor
final class WhisperKitTranscriptionFailureTests: XCTestCase {
    private let audioPath = URL(fileURLWithPath: "/tmp/whisperkit-failure-test.wav")

    // MARK: - Result-to-segments mapping (pure)

    func testFailureIsThrownWithTheDecodersMessage() {
        let result: Result<[TranscriptionResult], any Error> =
            .failure(WhisperError.decodingFailed("logits were NaN"))

        XCTAssertThrowsError(try WhisperKitEngine.segments(from: result)) { error in
            XCTAssertFalse(error is CancellationError, "a real failure was reported as a cancellation")
            XCTAssertEqual(
                error.localizedDescription,
                "WhisperKit transcription failed: logits were NaN",
            )
        }
    }

    func testCancellationErrorIsRethrownAsCancellation() {
        let result: Result<[TranscriptionResult], any Error> = .failure(CancellationError())

        XCTAssertThrowsError(try WhisperKitEngine.segments(from: result)) { error in
            XCTAssertTrue(error is CancellationError, "got \(error) instead of CancellationError")
        }
    }

    func testMissingResultIsAFailureNotAnEmptyTranscript() {
        XCTAssertThrowsError(try WhisperKitEngine.segments(from: nil)) { error in
            XCTAssertFalse(error is CancellationError)
            XCTAssertTrue(error.localizedDescription.hasPrefix("WhisperKit transcription failed"))
        }
    }

    func testSuccessWithoutSpeechStaysEmpty() throws {
        XCTAssertTrue(try WhisperKitEngine.segments(from: .success([])).isEmpty)
        XCTAssertTrue(
            try WhisperKitEngine.segments(from: .success([Self.result(segments: [])])).isEmpty,
        )
    }

    func testSuccessMapsSegmentsAndDropsRepeats() throws {
        let result = Self.result(segments: [
            TranscriptionSegment(start: 0, end: 2, text: "<|0.00|> Hello<|2.00|>"),
            TranscriptionSegment(start: 2, end: 4, text: " Hello"),
            TranscriptionSegment(start: 4, end: 6, text: " "),
            TranscriptionSegment(start: 6, end: 8, text: " World"),
        ])

        let segments = try WhisperKitEngine.segments(from: .success([result]))

        XCTAssertEqual(segments.map(\.text), ["Hello", "World"])
        XCTAssertEqual(segments.map(\.start), [0, 6])
        XCTAssertEqual(segments.map(\.end), [2, 8])
    }

    // MARK: - Through the engine, at the decoder seam

    func testEngineThrowsCancellationForACancelledDecode() async {
        let engine = WhisperKitEngine()
        engine.installDecodingClientForTesting(ScriptedWhisperDecodingClient(fileResult: .failure(CancellationError())))

        do {
            _ = try await engine.transcribeSegments(audioPath: audioPath)
            XCTFail("a cancelled decode returned a transcript")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error) instead of CancellationError")
        }
    }

    // MARK: - Through the pipeline

    /// The user-facing point of the change: a job whose transcription failed
    /// says why, instead of claiming the recording was silent.
    func testPipelineJobCarriesTheWhisperKitFailure() async throws {
        let tmpDir = try makeTempDirectory(prefix: "whisperkit_failure_test")
        let engine = WhisperKitEngine()
        engine.installDecodingClientForTesting(
            ScriptedWhisperDecodingClient(fileResult: .failure(WhisperError.modelsUnavailable("encoder missing"))),
        )
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir,
            diarizeEnabled: false,
            micLabel: "Me",
        )
        let job = try PipelineJob(
            meetingTitle: "Failing Call", appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
        )

        queue.enqueue(job)
        await queue.awaitProcessing()

        let failed = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(failed.state, .error)
        XCTAssertEqual(failed.error, "WhisperKit transcription failed: encoder missing")
    }

    private static func result(segments: [TranscriptionSegment]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.text).joined(),
            segments: segments,
            language: "en",
            timings: TranscriptionTimings(),
        )
    }
}

/// Answers every file decode with one canned result.
@MainActor
private final class ScriptedWhisperDecodingClient: WhisperDecodingClient {
    let tokenizer: (any WhisperTokenizer)? = nil
    private let fileResult: Result<[TranscriptionResult], any Error>

    init(fileResult: Result<[TranscriptionResult], any Error>) {
        self.fileResult = fileResult
    }

    func transcribeFile(
        audioPaths _: [String],
        decodeOptions _: DecodingOptions,
        callback _: TranscriptionCallback,
    ) -> [Result<[TranscriptionResult], any Error>] {
        [fileResult]
    }

    func transcribeSamples(_: [Float], decodeOptions _: DecodingOptions) -> [TranscriptionResult] {
        []
    }
}
