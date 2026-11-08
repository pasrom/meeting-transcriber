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

    /// Live captions run the same hallucination filter and join what is left.
    func testLiveSamplesAreFilteredAndJoined() async throws {
        let engine = WhisperKitEngine()
        engine.installDecodingClientForTesting(ScriptedWhisperDecodingClient(sampleResults: [
            Self.result(segments: [
                TranscriptionSegment(text: "<|0.00|> Hello"),
                TranscriptionSegment(text: " Hello"),
            ]),
            Self.result(segments: [
                TranscriptionSegment(text: " "),
                TranscriptionSegment(text: " World<|1.00|>"),
            ]),
        ]))

        let text = try await engine.transcribeSamples([0])

        XCTAssertEqual(text, "Hello World")
    }

    func testDetectionConvertsTopLogProbabilityToConfidence() throws {
        let result = try XCTUnwrap(WhisperKitEngine.languageDetection(logProbabilities: [
            "en": log(0.9), "de": log(0.1),
        ]))
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.probability, 0.9, accuracy: 0.0001)
        XCTAssertNil(WhisperKitEngine.languageDetection(logProbabilities: [:]))
    }

    func testDetectionLoadsAnUnloadedModelBeforeProbing() async {
        let engine = WhisperKitEngine()
        var downloadAttempts = 0
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                downloadAttempts += 1
                throw URLError(.networkConnectionLost)
            },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))

        do {
            _ = try await engine.detectLanguage(samples: [0])
            XCTFail("A failed model load must prevent detection")
        } catch {
            XCTAssertEqual(engine.modelState, .unloaded)
        }
        XCTAssertEqual(downloadAttempts, 1, "Detection must try to load on first recording")
    }

    func testDetectionReadsTheDecoderLanguageProbabilities() async throws {
        let engine = WhisperKitEngine()
        let client = ScriptedWhisperDecodingClient(languageLogProbabilities: ["en": log(0.2), "id": log(0.8)])
        engine.installDecodingClientForTesting(client)

        let result = try await engine.detectLanguage(samples: [0.5])

        XCTAssertEqual(result?.language, "id")
        XCTAssertEqual(result?.probability ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(client.detectedSamples, [[0.5]])
        XCTAssertTrue(engine.supportsCaptionLanguageDetection)
    }

    func testEnglishOnlyModelReportsNoDetection() async throws {
        let engine = WhisperKitEngine()
        let client = ScriptedWhisperDecodingClient(isMultilingual: false, languageLogProbabilities: ["en": 0])
        engine.installDecodingClientForTesting(client)

        XCTAssertFalse(engine.supportsCaptionLanguageDetection)
        let result = try await engine.detectLanguage(samples: [0.5])
        XCTAssertNil(result)
        XCTAssertTrue(client.detectedSamples.isEmpty, "WhisperKit throws for an English-only model")
    }

    func testReleasedEnglishOnlyModelStillReportsNoDetection() {
        let engine = WhisperKitEngine()
        engine.installDecodingClientForTesting(ScriptedWhisperDecodingClient(isMultilingual: false, languageLogProbabilities: [:]))
        engine.releaseModel()
        engine.installDecodingClientForTesting(nil)
        XCTAssertFalse(engine.supportsCaptionLanguageDetection, "an idle unload must not flip the footnote")
        engine.applyModelVariant("openai_whisper-small")
        XCTAssertTrue(engine.supportsCaptionLanguageDetection, "another model is not known yet")
    }

    func testOtherEnginesDefaultToUnsupportedDetection() {
        let engine = MockStreamingEngine()
        XCTAssertFalse(engine.supportsCaptionLanguageDetection)
        let result = engine.detectLanguage(samples: [0])
        XCTAssertNil(result)
    }

    func testStringSamplesKeepConfiguredLanguageAndSingleDecode() async throws {
        let engine = WhisperKitEngine()
        engine.language = "de"
        let client = ScriptedWhisperDecodingClient(sampleResults: [
            Self.result(segments: [TranscriptionSegment(text: "<|de|> Hallo")], language: "de"),
        ])
        engine.installDecodingClientForTesting(client)

        let text = try await engine.transcribeSamples([0])

        XCTAssertEqual(text, "Hallo")
        XCTAssertEqual(client.sampleCallCount, 1)
        XCTAssertEqual(client.sampleOptions?.language, "de")
        XCTAssertEqual(client.sampleOptions?.detectLanguage, false)
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

    private static func result(segments: [TranscriptionSegment], language: String = "en") -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.text).joined(),
            segments: segments,
            language: language,
            timings: TranscriptionTimings(),
        )
    }
}

/// Answers every file decode with one canned result.
@MainActor
private final class ScriptedWhisperDecodingClient: WhisperDecodingClient {
    let tokenizer: (any WhisperTokenizer)? = nil
    private let fileResult: Result<[TranscriptionResult], any Error>
    private let sampleResults: [TranscriptionResult]
    private(set) var sampleCallCount = 0
    private(set) var sampleOptions: DecodingOptions?
    let isMultilingual: Bool
    private let languageLogProbabilities: [String: Float]
    private(set) var detectedSamples: [[Float]] = []

    init(
        fileResult: Result<[TranscriptionResult], any Error> = .success([]),
        sampleResults: [TranscriptionResult] = [],
        isMultilingual: Bool = true,
        languageLogProbabilities: [String: Float] = [:],
    ) {
        self.fileResult = fileResult
        self.sampleResults = sampleResults
        self.isMultilingual = isMultilingual
        self.languageLogProbabilities = languageLogProbabilities
    }

    func languageLogProbabilities(samples: [Float]) -> [String: Float] {
        detectedSamples.append(samples)
        return languageLogProbabilities
    }

    func transcribeFile(
        audioPaths _: [String],
        decodeOptions _: DecodingOptions,
        callback _: TranscriptionCallback,
    ) -> [Result<[TranscriptionResult], any Error>] {
        [fileResult]
    }

    func transcribeSamples(_: [Float], decodeOptions: DecodingOptions) -> [TranscriptionResult] {
        sampleCallCount += 1
        sampleOptions = decodeOptions
        return sampleResults
    }
}
