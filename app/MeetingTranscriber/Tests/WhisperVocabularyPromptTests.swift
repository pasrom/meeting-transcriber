@testable import MeetingTranscriber
import XCTest

final class WhisperVocabularyPromptTests: XCTestCase {
    func testDefaultPromptBudgetLeavesMostOfWhisperKitsDecoderContextForSpeech() {
        // WhisperKit 1.1.0 uses a 224-token context for prompt + generation.
        // The four control/start tokens and this prompt still leave at least
        // 80% of the context available for generated speech tokens.
        XCTAssertLessThanOrEqual(WhisperVocabularyPrompt.defaultTokenBudget, 40)
        XCTAssertGreaterThanOrEqual(224 - 4 - WhisperVocabularyPrompt.defaultTokenBudget, 180)
    }

    func testTerms_preservesFirstOccurrenceAndFileOrder() {
        let terms = WhisperVocabularyPrompt.terms(
            from: "  Northstar  \n\nMikael\nNorthstar\n  Mikael  \nAster\n",
        )

        XCTAssertEqual(terms, ["Northstar", "Mikael", "Aster"])
    }

    func testTermsTreatsCasingVariantsAsOneVocabularyEntry() {
        XCTAssertEqual(
            WhisperVocabularyPrompt.terms(from: "Northstar\nnorthstar\nNORTHSTAR\n"),
            ["Northstar"],
        )
    }

    func testPromptTokens_acceptsOnlyCompleteTermsWithinBudget() {
        let tokens = WhisperVocabularyPrompt.tokens(
            for: ["Northstar", "Mikael", "Aster"],
            tokenize: { term in
                switch term {
                case " Northstar": [11, 12]
                case " Mikael": [13, 14, 15]
                case " Aster": [16]
                default: []
                }
            },
            specialTokenBegin: 500,
            tokenBudget: 4,
        )

        XCTAssertEqual(tokens, [11, 12, 16])
    }

    func testPromptTokens_filtersTokenizerWrapperTokensBeforeBudgeting() {
        let tokens = WhisperVocabularyPrompt.tokens(
            for: ["Northstar", "Mikael"],
            tokenize: { term in
                switch term {
                case " Northstar": [21, 700, 22]
                case " Mikael": [31, 32]
                default: []
                }
            },
            specialTokenBegin: 500,
            tokenBudget: 8,
        )

        XCTAssertEqual(tokens, [21, 22, 31, 32])
    }

    func testPromptTokens_stopsTokenizingOnceBudgetIsFull() {
        var tokenizedTerms: [String] = []
        let tokens = WhisperVocabularyPrompt.tokens(
            for: ["Northstar", "Mikael", "Aster"],
            tokenize: { term in
                tokenizedTerms.append(term)
                return switch term {
                case " Northstar": [31, 32]
                case " Mikael": [33]
                case " Aster": [34]
                default: []
                }
            },
            specialTokenBegin: 500,
            tokenBudget: 2,
        )

        XCTAssertEqual(tokens, [31, 32])
        XCTAssertEqual(tokenizedTerms, [" Northstar"])
    }

    func testPromptTokens_canFillTheDefaultBudgetWithCompleteTerms() {
        let terms = (0 ..< WhisperVocabularyPrompt.defaultTokenBudget).map { "Term\($0)" }
        let tokens = WhisperVocabularyPrompt.tokens(
            for: terms,
            tokenize: { _ in [7] },
            specialTokenBegin: 500,
        )

        XCTAssertEqual(tokens.count, WhisperVocabularyPrompt.defaultTokenBudget)
    }

    func testTermsFromFile_returnsNilForEmptyOrUnreadablePath() {
        XCTAssertNil(WhisperVocabularyPrompt.terms(fromFileAt: ""))
        XCTAssertNil(
            WhisperVocabularyPrompt.terms(
                fromFileAt: "/tmp/not-present-vocabulary-\(UUID().uuidString).txt",
            ),
        )
    }

    func testTermsFromFile_acceptsExactly256UniqueTerms() throws {
        let contents = (0 ..< 256).map { "Term\($0)" }.joined(separator: "\n")
        let file = try makeVocabularyFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(WhisperVocabularyPrompt.terms(fromFileAt: file.path)?.count, 256)
    }

    func testTermsFromFile_rejects257UniqueTerms() throws {
        let contents = (0 ... 256).map { "Term\($0)" }.joined(separator: "\n")
        let file = try makeVocabularyFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNil(WhisperVocabularyPrompt.terms(fromFileAt: file.path))
    }

    func testTermsFromFile_acceptsA512ByteTerm() throws {
        let term = String(repeating: "x", count: 512)
        let file = try makeVocabularyFile(contents: term)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(WhisperVocabularyPrompt.terms(fromFileAt: file.path), [term])
    }

    func testTermsFromFile_rejectsA513ByteTerm() throws {
        let term = String(repeating: "x", count: 513)
        let file = try makeVocabularyFile(contents: term)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNil(WhisperVocabularyPrompt.terms(fromFileAt: file.path))
    }

    func testCacheKey_changesWhenVocabularyPathOrModelChanges() {
        let baseline = WhisperVocabularyPrompt.CacheKey(
            vocabularyPath: "/tmp/first.txt",
            modelVariant: "openai_whisper-small",
            vocabularyRevision: .init(fileID: 1, modificationTime: .distantPast, fileSize: 10),
        )
        let changedPath = WhisperVocabularyPrompt.CacheKey(
            vocabularyPath: "/tmp/second.txt",
            modelVariant: "openai_whisper-small",
            vocabularyRevision: .init(fileID: 1, modificationTime: .distantPast, fileSize: 10),
        )
        let changedModel = WhisperVocabularyPrompt.CacheKey(
            vocabularyPath: "/tmp/first.txt",
            modelVariant: "openai_whisper-base",
            vocabularyRevision: .init(fileID: 1, modificationTime: .distantPast, fileSize: 10),
        )
        let changedContents = WhisperVocabularyPrompt.CacheKey(
            vocabularyPath: "/tmp/first.txt",
            modelVariant: "openai_whisper-small",
            vocabularyRevision: .init(fileID: 1, modificationTime: .distantFuture, fileSize: 10),
        )

        XCTAssertNotEqual(baseline, changedPath)
        XCTAssertNotEqual(baseline, changedModel)
        XCTAssertNotEqual(baseline, changedContents)

        var cache = WhisperVocabularyPrompt.TokenCache()
        cache.store([31, 32], for: baseline)
        XCTAssertEqual(cache.value(for: baseline), .prompt([31, 32]))
        XCTAssertNil(cache.value(for: changedPath))
        XCTAssertNil(cache.value(for: changedModel))
        XCTAssertNil(cache.value(for: changedContents))
        cache.invalidate()
        XCTAssertNil(cache.value(for: baseline))
    }

    private func makeVocabularyFile(contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-prompt-\(UUID().uuidString).txt")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
