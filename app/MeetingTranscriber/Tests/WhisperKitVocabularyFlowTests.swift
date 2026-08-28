import Foundation
@testable import MeetingTranscriber
import WhisperKit
import XCTest

// swiftlint:disable discouraged_optional_collection

@MainActor
final class WhisperKitVocabularyFlowTests: XCTestCase {
    func testDisabledVocabularyPromptSkipsFileAccessForBothWhisperKitFlows() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let loader = VocabularyTermsLoaderSpy()
        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = vocabularyFile.path
        engine.installVocabularyTermsLoaderForTesting { _, _ in
            loader.loadCount += 1
            return .loaded(["Northstar"])
        }
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/empty.wav"))
        _ = try await engine.transcribeSamples([0])

        XCTAssertEqual(loader.loadCount, 0)
        XCTAssertEqual(client.filePrompts, [.noPrompt])
        XCTAssertEqual(client.samplePrompts, [.noPrompt])
    }

    func testEnabledVocabularyPromptTokensReachBothWhisperKitFlows() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = vocabularyFile.path
        engine.vocabularyPromptEnabled = true
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/empty.wav"))
        _ = try await engine.transcribeSamples([0])

        XCTAssertEqual(client.filePrompts, [.tokens([101, 102])])
        XCTAssertEqual(client.samplePrompts, [.tokens([101, 102])])
    }

    func testSamePathEditAndDeletionDoNotReuseStaleVocabularyTokens() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = vocabularyFile.path
        engine.vocabularyPromptEnabled = true
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/empty.wav"))
        try "Mikael\n".write(to: vocabularyFile, atomically: true, encoding: .utf8)
        _ = try await engine.transcribeSamples([0])
        try FileManager.default.removeItem(at: vocabularyFile)
        _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/empty.wav"))

        XCTAssertEqual(client.filePrompts, [.tokens([101, 102]), .noPrompt])
        XCTAssertEqual(client.samplePrompts, [.tokens([103])])
    }

    func testMissingVocabularyFilePassesNoPromptToBothWhisperKitFlows() async throws {
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-vocabulary-\(UUID().uuidString).txt")
        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = missingFile.path
        engine.vocabularyPromptEnabled = true
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/empty.wav"))
        _ = try await engine.transcribeSamples([0])

        XCTAssertEqual(client.filePrompts, [.noPrompt])
        XCTAssertEqual(client.samplePrompts, [.noPrompt])
    }

    func testSecurityScopedBookmarkSuppliesVocabularyAfterPathChanges() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = "/missing/legacy-path.txt"
        engine.customVocabularyBookmark = try vocabularyFile.bookmarkData(options: .withSecurityScope)
        engine.vocabularyPromptEnabled = true
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSamples([0])

        XCTAssertEqual(client.samplePrompts, [.tokens([101, 102])])
    }

    func testUnchangedVocabularyRevisionUsesCachedTokensWithoutReloadingFile() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let loader = VocabularyTermsLoaderSpy()
        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = vocabularyFile.path
        engine.vocabularyPromptEnabled = true
        engine.installVocabularyTermsLoaderForTesting { _, _ in
            loader.loadCount += 1
            return .loaded(["Northstar"])
        }
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSamples([0])
        _ = try await engine.transcribeSamples([0])

        XCTAssertEqual(loader.loadCount, 1)
        XCTAssertEqual(client.samplePrompts, [.tokens([101, 102]), .tokens([101, 102])])
    }

    func testOversizedVocabularyFilePassesNoPromptAndDoesNotCallLoader() async throws {
        let oversizedContents = String(
            repeating: "x",
            count: WhisperVocabularyPrompt.maximumFileBytes + 1,
        )
        let vocabularyFile = try makeVocabularyFile(contents: oversizedContents)
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let loader = VocabularyTermsLoaderSpy()
        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = vocabularyFile.path
        engine.vocabularyPromptEnabled = true
        engine.installVocabularyTermsLoaderForTesting { _, _ in
            loader.loadCount += 1
            return .loaded(["Northstar"])
        }
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSamples([0])

        XCTAssertEqual(loader.loadCount, 0)
        XCTAssertEqual(client.samplePrompts, [.noPrompt])
    }

    func testUnavailableRevisionIsCachedWithoutReloadingTerms() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let loader = VocabularyTermsLoaderSpy()
        let client = CapturingWhisperDecodingClient()
        let engine = WhisperKitEngine()
        engine.customVocabularyPath = vocabularyFile.path
        engine.vocabularyPromptEnabled = true
        engine.installVocabularyTermsLoaderForTesting { _, _ in
            loader.loadCount += 1
            return .unavailable
        }
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSamples([0])
        _ = try await engine.transcribeSamples([0])

        XCTAssertEqual(loader.loadCount, 1)
        XCTAssertEqual(client.samplePrompts, [.noPrompt, .noPrompt])
    }

    private func makeVocabularyFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

@MainActor
private final class CapturingWhisperDecodingClient: WhisperDecodingClient {
    let tokenizer: (any WhisperTokenizer)? = VocabularyTestTokenizer()
    private(set) var filePrompts: [PromptObservation] = []
    private(set) var samplePrompts: [PromptObservation] = []

    func transcribeFile(
        audioPaths _: [String],
        decodeOptions: DecodingOptions,
        callback _: TranscriptionCallback,
    ) -> [[TranscriptionResult]?] {
        filePrompts.append(PromptObservation(decodeOptions.promptTokens))
        return [[]]
    }

    func transcribeSamples(
        _: [Float],
        decodeOptions: DecodingOptions,
    ) -> [TranscriptionResult] {
        samplePrompts.append(PromptObservation(decodeOptions.promptTokens))
        return []
    }
}

private enum PromptObservation: Equatable {
    case noPrompt
    case tokens([Int])

    init(_ tokens: [Int]?) {
        self = tokens.map(Self.tokens) ?? .noPrompt
    }
}

@MainActor
private final class VocabularyTermsLoaderSpy {
    var loadCount = 0
}

private final class VocabularyTestTokenizer: WhisperTokenizer {
    let specialTokens = SpecialTokens(
        endToken: 500,
        englishToken: 501,
        noSpeechToken: 502,
        noTimestampsToken: 503,
        specialTokenBegin: 500,
        startOfPreviousToken: 504,
        startOfTranscriptToken: 505,
        timeTokenBegin: 506,
        transcribeToken: 507,
        translateToken: 508,
        whitespaceToken: 509,
    )
    let allLanguageTokens: Set<Int> = []

    func encode(text: String) -> [Int] {
        switch text {
        case " Northstar": [101, 102]
        case " Mikael": [103]
        default: []
        }
    }

    func decode(tokens _: [Int]) -> String {
        ""
    }

    func convertTokenToId(_: String) -> Int? {
        nil
    }

    func convertIdToToken(_: Int) -> String? {
        nil
    }

    func splitToWordTokens(tokenIds _: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        ([], [])
    }
}

// swiftlint:enable discouraged_optional_collection
