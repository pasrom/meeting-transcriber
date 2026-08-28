import FluidAudio
@testable import MeetingTranscriber
import XCTest

@MainActor
final class ParakeetVocabularyPreparationTests: XCTestCase {
    func testVocabularyPreparationReceivesValidatedDeduplicatedTerms() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\nnorthstar\nAster\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = ParakeetEngine()
        engine.customVocabularyPath = vocabularyFile.path
        var preparedTerms: [String] = []
        engine.installVocabularyPreparationForTesting { terms in
            preparedTerms = terms
        }

        await engine.ensureVocabularyConfiguration()

        XCTAssertEqual(preparedTerms, ["Northstar", "Aster"])
    }

    func testVocabularyPreparationFailureIsContainedAndNotRetriedForTheSameConfiguration() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = ParakeetEngine()
        engine.customVocabularyPath = vocabularyFile.path
        var attempts = 0
        engine.installVocabularyPreparationForTesting { _ in
            attempts += 1
            throw PreparationError.failed
        }

        await engine.ensureVocabularyConfiguration()
        await engine.ensureVocabularyConfiguration()

        XCTAssertEqual(attempts, 1)
    }

    func testVocabularyPreparationRetriesAfterTheFileRevisionChanges() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = ParakeetEngine()
        engine.customVocabularyPath = vocabularyFile.path
        var attempts = 0
        engine.installVocabularyPreparationForTesting { _ in
            attempts += 1
            throw PreparationError.failed
        }

        await engine.ensureVocabularyConfiguration()
        try "Aster\n".write(to: vocabularyFile, atomically: true, encoding: .utf8)
        await engine.ensureVocabularyConfiguration()

        XCTAssertEqual(attempts, 2)
    }

    func testFailedBatchVocabularyPreparationFallsBackToTheTranscript() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = ParakeetEngine()
        engine.customVocabularyPath = vocabularyFile.path
        var preparationAttempts = 0
        engine.installVocabularyPreparationForTesting { _ in
            preparationAttempts += 1
            throw PreparationError.failed
        }
        engine.installTranscriptionForTesting(
            file: { _ in Self.transcriptionResult(text: "Fallback transcript") },
            samples: { _ in Self.transcriptionResult(text: "Live transcript") },
        )

        let segments = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/input.wav"))

        XCTAssertEqual(segments.map(\.text), ["Fallback transcript"])
        XCTAssertEqual(preparationAttempts, 1)
    }

    func testLiveTranscriptionDoesNotPrepareVocabulary() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = ParakeetEngine()
        engine.customVocabularyPath = vocabularyFile.path
        var preparationAttempts = 0
        engine.installVocabularyPreparationForTesting { _ in
            preparationAttempts += 1
            throw PreparationError.failed
        }
        engine.installTranscriptionForTesting(
            file: { _ in Self.transcriptionResult(text: "Batch transcript") },
            samples: { _ in Self.transcriptionResult(text: "Live transcript") },
        )

        let transcript = try await engine.transcribeSamples([0])

        XCTAssertEqual(transcript, "Live transcript")
        XCTAssertEqual(preparationAttempts, 0)
    }

    func testModelLoadDoesNotPrepareVocabulary() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = ParakeetEngine()
        engine.customVocabularyPath = vocabularyFile.path
        var preparationAttempts = 0
        engine.installVocabularyPreparationForTesting { _ in
            preparationAttempts += 1
        }

        await engine.loadModel()

        XCTAssertEqual(preparationAttempts, 0)
    }

    func testVocabularyPreparationRefreshesAfterTheFileChanges() async throws {
        let vocabularyFile = try makeVocabularyFile(contents: "Northstar\n")
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = ParakeetEngine()
        engine.customVocabularyPath = vocabularyFile.path
        var preparedTermLists: [[String]] = []
        engine.installVocabularyPreparationForTesting { terms in
            preparedTermLists.append(terms)
        }

        await engine.ensureVocabularyConfiguration()
        await engine.ensureVocabularyConfiguration()
        try "Aster\nVega\n".write(to: vocabularyFile, atomically: true, encoding: .utf8)
        await engine.ensureVocabularyConfiguration()

        XCTAssertEqual(preparedTermLists, [["Northstar"], ["Aster", "Vega"]])
    }

    private func makeVocabularyFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-vocabulary-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func transcriptionResult(text: String) -> ASRResult {
        ASRResult(text: text, confidence: 1, duration: 1, processingTime: 0.01)
    }

    private enum PreparationError: Error, Equatable {
        case failed
    }
}
