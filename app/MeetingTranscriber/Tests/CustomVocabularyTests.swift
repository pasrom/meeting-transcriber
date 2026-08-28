import Foundation
@testable import MeetingTranscriber
import XCTest

final class CustomVocabularyTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite — see AppSettingsTests for why.
    override func setUp() {
        super.setUp()
        testSuiteName = "CustomVocabularyTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        settings = nil
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        super.tearDown()
    }

    // MARK: - Default

    func testCustomVocabularyPathDefault() {
        XCTAssertEqual(settings.customVocabularyPath, "")
    }

    func testWhisperKitVocabularyPromptDefaultsOffAndPersists() {
        XCTAssertFalse(settings.whisperKitVocabularyPromptEnabled)

        settings.whisperKitVocabularyPromptEnabled = true

        XCTAssertTrue(defaults.bool(forKey: "whisperKitVocabularyPromptEnabled"))
        XCTAssertTrue(AppSettings(defaults: defaults).whisperKitVocabularyPromptEnabled)
    }

    // MARK: - Persistence

    func testCustomVocabularyPathPersists() {
        settings.setCustomVocabularyPath("/tmp/vocab.txt")
        XCTAssertEqual(settings.customVocabularyPath, "/tmp/vocab.txt")

        // Verify it persists to the injected store.
        XCTAssertEqual(defaults.string(forKey: "customVocabularyPath"), "/tmp/vocab.txt")
    }

    func testCustomVocabularyPathClear() {
        settings.setCustomVocabularyPath("/tmp/vocab.txt")
        settings.clearCustomVocabularyFile()
        XCTAssertEqual(settings.customVocabularyPath, "")
    }

    func testSelectedVocabularyFilePersistsBookmarkAndResolvesAfterReload() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-bookmark-\(UUID().uuidString).txt")
        try "Northstar\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        settings.setCustomVocabularyFile(file)

        let bookmark = try XCTUnwrap(settings.customVocabularyBookmark)
        XCTAssertEqual(settings.customVocabularyPath, file.path)
        XCTAssertEqual(defaults.data(forKey: "customVocabularyBookmark"), bookmark)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(
            reloaded.customVocabularyFile?.resolvingSymlinksInPath().path,
            file.resolvingSymlinksInPath().path,
        )
    }

    func testClearingVocabularyFileClearsPathAndBookmark() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-bookmark-\(UUID().uuidString).txt")
        try "Northstar\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        settings.setCustomVocabularyFile(file)

        settings.clearCustomVocabularyFile()

        XCTAssertEqual(settings.customVocabularyPath, "")
        XCTAssertNil(settings.customVocabularyBookmark)
    }

    func testVocabularyValidationReportsUsableTermCount() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-validation-\(UUID().uuidString).txt")
        try "Northstar\nNorthstar\nAster\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        settings.setCustomVocabularyFile(file)

        XCTAssertEqual(settings.customVocabularyValidation, .ready(termCount: 2))
    }

    func testVocabularyValidationRejectsAnEmptyFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-empty-\(UUID().uuidString).txt")
        try "\n  \n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        settings.setCustomVocabularyFile(file)

        XCTAssertEqual(settings.customVocabularyValidation, .empty)
    }

    func testVocabularyValidationAccepts256TermsAndRejects257() throws {
        let acceptedTerms = (0 ..< 256).map { "Term\($0)" }
        let acceptedFile = try makeVocabularyFile(contents: acceptedTerms.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: acceptedFile) }

        settings.setCustomVocabularyFile(acceptedFile)

        XCTAssertEqual(settings.customVocabularyValidation, .ready(termCount: 256))

        let rejectedTerms = (0 ... 256).map { "Term\($0)" }
        let rejectedFile = try makeVocabularyFile(contents: rejectedTerms.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: rejectedFile) }

        settings.setCustomVocabularyFile(rejectedFile)

        XCTAssertEqual(settings.customVocabularyValidation, .tooManyTerms)
    }

    func testVocabularyValidationAccepts512ByteTermAndRejects513ByteTerm() throws {
        let acceptedTerm = String(repeating: "x", count: 512)
        let acceptedFile = try makeVocabularyFile(contents: acceptedTerm)
        defer { try? FileManager.default.removeItem(at: acceptedFile) }

        settings.setCustomVocabularyFile(acceptedFile)

        XCTAssertEqual(settings.customVocabularyValidation, .ready(termCount: 1))

        let rejectedTerm = String(repeating: "x", count: 513)
        let rejectedFile = try makeVocabularyFile(contents: rejectedTerm)
        defer { try? FileManager.default.removeItem(at: rejectedFile) }

        settings.setCustomVocabularyFile(rejectedFile)

        XCTAssertEqual(settings.customVocabularyValidation, .termTooLong)
    }

    func testTerminologyRulesPersist() {
        settings.terminologyRulesText = "Aster => Astor"

        XCTAssertEqual(defaults.string(forKey: "terminologyRulesText"), "Aster => Astor")
        XCTAssertEqual(AppSettings(defaults: defaults).terminologyRulesText, "Aster => Astor")
    }

    func testManualVocabularyPathEditClearsPreviousBookmark() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-bookmark-\(UUID().uuidString).txt")
        try "Northstar\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        settings.setCustomVocabularyFile(file)

        settings.setCustomVocabularyPath("/tmp/manual-vocabulary.txt")

        XCTAssertEqual(settings.customVocabularyPath, "/tmp/manual-vocabulary.txt")
        XCTAssertNil(settings.customVocabularyBookmark)
    }

    private func makeVocabularyFile(contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-validation-\(UUID().uuidString).txt")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
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
}
