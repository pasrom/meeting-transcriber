import Foundation
@testable import MeetingTranscriber
import WhisperKit
import XCTest

@MainActor
final class WhisperTranslationTests: XCTestCase {
    func testTranslationKeepsSourceAutoDetectionAndTimestamps() {
        let options = WhisperKitEngine.decodingOptions(language: nil, outputMode: .translateToEnglish)
        XCTAssertEqual(options.task, .translate)
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertFalse(options.wordTimestamps)
    }

    func testOriginalOutputRemainsTranscriptionAndExplicitLanguageRemainsSource() {
        let original = WhisperKitEngine.decodingOptions(language: nil)
        XCTAssertEqual(original.task, .transcribe)
        let translation = WhisperKitEngine.decodingOptions(language: "zh", outputMode: .translateToEnglish)
        XCTAssertEqual(translation.task, .translate)
        XCTAssertEqual(translation.language, "zh")
        XCTAssertFalse(translation.detectLanguage)
    }

    func testTranslationModelPolicyRejectsTurboEnglishOnlyAndUnknownModels() {
        for model in ["openai_whisper-small", "openai_whisper-large-v2", "openai_whisper-large-v3-v20240930"] {
            XCTAssertTrue(WhisperOutputMode.supportsTranslation(modelVariant: model))
        }
        for model in ["openai_whisper-large-v3-v20240930_turbo", "openai_whisper-small.en", "unknown"] {
            XCTAssertFalse(WhisperOutputMode.supportsTranslation(modelVariant: model))
        }
    }

    func testSettingsDefaultPersistenceAndCapability() throws {
        let name = "WhisperTranslationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { DefaultsSuite.remove(name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.whisperOutputMode, .original)
        settings.whisperOutputMode = .translateToEnglish
        XCTAssertEqual(AppSettings(defaults: defaults).whisperOutputMode, .translateToEnglish)
        XCTAssertFalse(settings.liveEngineSupportsTranscription, "Default Turbo cannot translate")
        settings.whisperKitModel = "openai_whisper-small"
        XCTAssertTrue(settings.liveTranslationEnabled)
        XCTAssertTrue(settings.liveEngineSupportsTranscription)
        settings.transcriptionEngine = .parakeet
        XCTAssertFalse(settings.liveTranslationEnabled)
        XCTAssertNil(settings.transcriptionConfiguration.whisper)
    }

    func testBothDecoderFlowsUseTranslationAndKeepSegmentTiming() async throws {
        let (engine, client) = translationEngine()
        let segments = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/test.wav"))
        let live = try await engine.transcribeSamples([0])
        XCTAssertEqual(client.fileOptions.map(\.task), [.translate])
        XCTAssertEqual(client.sampleOptions.map(\.task), [.translate])
        XCTAssertTrue(client.fileOptions.allSatisfy { $0.language == nil && $0.detectLanguage })
        XCTAssertTrue(client.sampleOptions.allSatisfy { $0.language == nil && $0.detectLanguage })
        XCTAssertEqual(segments.first?.text, "We will ship on Friday.")
        XCTAssertEqual(segments.first?.start, 1)
        XCTAssertEqual(segments.first?.end, 3)
        XCTAssertEqual(live, "We will ship on Friday.")
    }

    func testSessionKeepsTaskAndSourceAfterSettingsChangeAcrossBothTracks() async throws {
        let (engine, client) = translationEngine()
        let session = engine.session(for: engine.transcriptionConfiguration)
        _ = try await session.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/app.wav"))
        engine.outputMode = .original
        engine.language = "en"
        engine.applyModelVariant("openai_whisper-large-v3-v20240930_turbo")
        _ = try await session.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/mic.wav"))
        let live = try XCTUnwrap(session as? any StreamingTranscribingEngine)
        _ = try await live.transcribeSamples([0])
        XCTAssertEqual(client.fileOptions.map(\.task), [.translate, .translate])
        XCTAssertTrue(client.fileOptions.allSatisfy { $0.language == nil && $0.detectLanguage })
        XCTAssertEqual(client.sampleOptions.map(\.task), [.translate])
    }

    func testSessionCapturesSettingsBeforeFirstDecodeNotAfterWarmup() async throws {
        let (engine, client) = translationEngine()
        let session = engine.session(for: engine.transcriptionConfiguration)
        engine.outputMode = .original
        engine.language = "en"
        let live = try XCTUnwrap(session as? any StreamingTranscribingEngine)
        _ = try await live.transcribeSamples([0])
        XCTAssertEqual(client.sampleOptions.first?.task, .translate)
        XCTAssertNil(client.sampleOptions.first?.language)
    }

    func testUnsupportedModelFailsBeforeEitherDecoderIsCalled() async {
        let (engine, client) = translationEngine()
        engine.modelVariant = "openai_whisper-large-v3-v20240930_turbo"
        do {
            _ = try await engine.transcribeSamples([0])
            XCTFail("Turbo must not silently emit original-language captions")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
        do {
            _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/test.wav"))
            XCTFail("Turbo must not silently save an untranslated transcript")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
        XCTAssertTrue(client.fileOptions.isEmpty)
        XCTAssertTrue(client.sampleOptions.isEmpty)
    }

    func testSessionDoesNotRetryFailedLoadWithinTheSameAttempt() async {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        var downloads = 0
        engine.installModelSourceForTesting(.init(
            locateLocal: { _ in nil },
            download: { _, _ in
                downloads += 1
                throw TranscriptionError.modelNotLoaded
            },
            makePipe: { _, _ in throw TranscriptionError.modelNotLoaded },
        ))
        let session = engine.session(for: engine.transcriptionConfiguration)
        await session.loadModel()
        XCTAssertEqual(downloads, 1, "A frozen session must not repeat the shared engine's failed load")
    }

    /// Real-model smoke coverage for both decode entry points. Reuses the same
    /// multilingual Small model and German fixture as WhisperKitEngineTests;
    /// mixed English/Chinese quality and live latency still need field evidence.
    func testSmallTranslatesGermanFixtureToEnglishInFileAndSamplePaths() async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.outputMode = .translateToEnglish
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)

        let segments = try await engine.transcribeSegments(audioPath: fixtureURL())
        assertEnglish(segments.map(\.text).joined(separator: " "))
        let (samples, _) = try await AudioMixer.loadAudioAsFloat32(url: fixtureURL())
        let text = try await engine.transcribeSamples(Array(samples.prefix(16000 * 5)))
        assertEnglish(text)
    }

    private func assertEnglish(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        XCTAssertFalse(text.isEmpty, file: file, line: line)
        XCTAssertFalse(
            words.isDisjoint(with: ["the", "we", "and", "hello", "good", "you", "this", "is"]),
            "Expected English translation, got: \(text)", file: file, line: line,
        )
        XCTAssertTrue(
            words.isDisjoint(with: ["guten", "wir", "und", "ich", "das", "nicht"]),
            "German source words must not survive as the transcript: \(text)", file: file, line: line,
        )
    }

    private func translationEngine() -> (WhisperKitEngine, TranslationDecodingClient) {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.outputMode = .translateToEnglish
        let client = TranslationDecodingClient()
        engine.installDecodingClientForTesting(client)
        return (engine, client)
    }
}

/// Captures production decode options without loading a model. The English result
/// stands in for a decoder response; this proves plumbing, not model accuracy.
@MainActor
final class TranslationDecodingClient: WhisperDecodingClient {
    let tokenizer: (any WhisperTokenizer)? = nil
    var fileOptions: [DecodingOptions] = []
    var sampleOptions: [DecodingOptions] = []
    var onFileDecode: (() -> Void)?

    private func result() -> TranscriptionResult {
        TranscriptionResult(
            text: "We will ship on Friday.",
            segments: [.init(start: 1, end: 3, text: "We will ship on Friday.")],
            language: "zh", timings: TranscriptionTimings(),
        )
    }

    func transcribeFile(
        audioPaths _: [String], decodeOptions: DecodingOptions, callback _: TranscriptionCallback,
    ) -> [[TranscriptionResult]?] { // swiftlint:disable:this discouraged_optional_collection
        fileOptions.append(decodeOptions)
        onFileDecode?()
        return [[result()]]
    }

    func transcribeSamples(_: [Float], decodeOptions: DecodingOptions) -> [TranscriptionResult] {
        sampleOptions.append(decodeOptions)
        return [result()]
    }
}
