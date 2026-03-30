import Foundation
@testable import MeetingTranscriber
import XCTest

final class CustomVocabularyTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "customVocabularyPath")
        settings = AppSettings()
    }

    override func tearDown() {
        settings = nil
        super.tearDown()
    }

    // MARK: - Default

    func testCustomVocabularyPathDefault() {
        XCTAssertEqual(settings.customVocabularyPath, "")
    }

    // MARK: - Persistence

    func testCustomVocabularyPathPersists() {
        settings.customVocabularyPath = "/tmp/vocab.txt"
        XCTAssertEqual(settings.customVocabularyPath, "/tmp/vocab.txt")

        // Verify it persists to UserDefaults
        let stored = UserDefaults.standard.string(forKey: "customVocabularyPath")
        XCTAssertEqual(stored, "/tmp/vocab.txt")
    }

    func testCustomVocabularyPathClear() {
        settings.customVocabularyPath = "/tmp/vocab.txt"
        settings.customVocabularyPath = ""
        XCTAssertEqual(settings.customVocabularyPath, "")
    }

    // MARK: - ParakeetEngine vocabulary configuration

    @MainActor
    func testParakeetEngineHasCustomVocabularyPath() {
        let engine = ParakeetEngine()
        XCTAssertEqual(engine.customVocabularyPath, "")
    }

    @MainActor
    func testParakeetEngineVocabularyPathCanBeSet() {
        let engine = ParakeetEngine()
        engine.customVocabularyPath = "/tmp/test_vocab.txt"
        XCTAssertEqual(engine.customVocabularyPath, "/tmp/test_vocab.txt")
    }

    @MainActor
    func testConfigureVocabularySkipsEmptyPath() async throws {
        let engine = ParakeetEngine()
        // Should not throw for empty path
        try await engine.configureVocabulary(from: "")
    }

    @MainActor
    func testConfigureVocabularyLogsWarningForMissingFile() async throws {
        let engine = ParakeetEngine()
        // Should not throw for missing file — just logs a warning
        try await engine.configureVocabulary(from: "/nonexistent/vocab.txt")
    }
}
