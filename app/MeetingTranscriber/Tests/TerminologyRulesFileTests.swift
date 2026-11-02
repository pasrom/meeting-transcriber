import Foundation
@testable import MeetingTranscriber
import XCTest

final class TerminologyRulesFileTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite — see AppSettingsTests for why.
    override func setUp() {
        super.setUp()
        testSuiteName = "TerminologyRulesFileTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = DefaultsSuite.open(testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        settings = nil
        DefaultsSuite.remove(testSuiteName)
        defaults = nil
        testSuiteName = nil
        super.tearDown()
    }

    // MARK: - Text area stays the default

    func testWithoutAFileTheTextAreaRulesApply() {
        settings.terminologyRulesText = "Aster => Astor"

        XCTAssertFalse(settings.usesTerminologyRulesFile)
        XCTAssertEqual(settings.terminologyNormalizerForJob().normalize("Astor"), "Aster")
        XCTAssertEqual(settings.terminologyRulesValidation.message, "1 active terminology rule.")
    }

    // MARK: - Selection and bookmark

    func testSelectedRulesFilePersistsBookmarkAndResolvesAfterReload() throws {
        let file = try makeRulesFile(contents: "Aster => Astor\n")

        settings.setTerminologyRulesFile(file)

        let bookmark = try XCTUnwrap(settings.terminologyRulesFileBookmark)
        XCTAssertEqual(settings.terminologyRulesFilePath, file.path)
        XCTAssertEqual(defaults.data(forKey: "terminologyRulesFileBookmark"), bookmark)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(
            reloaded.terminologyRulesFile?.resolvingSymlinksInPath().path,
            file.resolvingSymlinksInPath().path,
        )
        XCTAssertEqual(reloaded.terminologyNormalizerForJob().normalize("Astor"), "Aster")
    }

    func testAStaleRulesFileBookmarkIsRepaired() throws {
        let directory = try makeTempDirectory(prefix: "terminology-stale")
        let file = directory.appendingPathComponent("rules.txt")
        try "Aster => Astor\n".write(to: file, atomically: true, encoding: .utf8)
        settings.setTerminologyRulesFile(file)
        let stale = try XCTUnwrap(settings.terminologyRulesFileBookmark)
        let moved = directory.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: file, to: moved)

        settings.repairStaleTerminologyRulesFileBookmark()

        XCTAssertEqual(
            URL(fileURLWithPath: settings.terminologyRulesFilePath).resolvingSymlinksInPath().path,
            moved.resolvingSymlinksInPath().path,
        )
        XCTAssertNotEqual(settings.terminologyRulesFileBookmark, stale)
        XCTAssertEqual(settings.terminologyNormalizerForJob().normalize("Astor"), "Aster")
    }

    func testManualPathEditClearsPreviousBookmark() throws {
        try settings.setTerminologyRulesFile(makeRulesFile(contents: "Aster => Astor\n"))

        settings.setTerminologyRulesFilePath("/tmp/manual-terminology.txt")

        XCTAssertEqual(settings.terminologyRulesFilePath, "/tmp/manual-terminology.txt")
        XCTAssertNil(settings.terminologyRulesFileBookmark)
    }

    func testClearingTheFileReturnsToTheTextArea() throws {
        settings.terminologyRulesText = "Northstar => northstar"
        try settings.setTerminologyRulesFile(makeRulesFile(contents: "Aster => Astor\n"))

        settings.clearTerminologyRulesFile()

        XCTAssertEqual(settings.terminologyRulesFilePath, "")
        XCTAssertNil(settings.terminologyRulesFileBookmark)
        XCTAssertEqual(settings.terminologyRulesFileContents, "")
        XCTAssertEqual(settings.terminologyNormalizerForJob().normalize("northstar Astor"), "Northstar Astor")
    }

    // MARK: - Read per job

    func testTheFileReplacesTheTextAreaAndFeedsThePreview() throws {
        settings.terminologyRulesText = "Northstar => northstar"
        let contents = "Aster => Astor\nnot a rule\n"

        try settings.setTerminologyRulesFile(makeRulesFile(contents: contents))

        let normalizer = settings.terminologyNormalizerForJob()
        XCTAssertEqual(normalizer.normalize("northstar Astor"), "northstar Aster")
        XCTAssertEqual(settings.terminologyRulesFileContents, contents)
        XCTAssertEqual(
            settings.terminologyRulesValidation.message,
            "1 active terminology rule. 1 invalid line was ignored.",
        )
    }

    func testAnEditToTheFileIsPickedUpByTheNextJob() throws {
        let file = try makeRulesFile(contents: "Aster => Astor\n")
        settings.setTerminologyRulesFile(file)
        let firstJob = settings.terminologyNormalizerForJob()

        try "Aster => Astor\nNorthstar => northstar\n".write(to: file, atomically: true, encoding: .utf8)
        let secondJob = settings.terminologyNormalizerForJob()

        XCTAssertEqual(firstJob.normalize("Astor northstar"), "Aster northstar", "a running job keeps its rules")
        XCTAssertEqual(secondJob.normalize("Astor northstar"), "Aster Northstar")
        XCTAssertEqual(settings.terminologyRulesValidation.message, "2 active terminology rules.")
    }

    // MARK: - A file that cannot be used applies no rules

    func testAnUnreadableFileAppliesNoRulesAndDoesNotFallBackToTheTextArea() throws {
        settings.terminologyRulesText = "Aster => Astor"
        let file = try makeRulesFile(contents: "Northstar => northstar\n")
        settings.setTerminologyRulesFile(file)
        try makeUnreadable(file)

        let normalizer = settings.terminologyNormalizerForJob()

        XCTAssertTrue(normalizer.isEmpty)
        XCTAssertEqual(normalizer.normalize("Astor northstar"), "Astor northstar")
        XCTAssertEqual(settings.terminologyRulesValidation, .fileUnavailable)
        XCTAssertEqual(settings.terminologyRulesFileContents, "")
    }

    func testAMissingFileAppliesNoRules() throws {
        settings.terminologyRulesText = "Aster => Astor"
        let file = try makeRulesFile(contents: "Northstar => northstar\n")
        settings.setTerminologyRulesFile(file)
        try FileManager.default.removeItem(at: file)

        XCTAssertTrue(settings.terminologyNormalizerForJob().isEmpty)
        XCTAssertEqual(settings.terminologyRulesValidation, .fileUnavailable)
    }

    func testAFileThatIsNotUTF8AppliesNoRules() throws {
        let file = try makeTempDirectory(prefix: "terminology-encoding").appendingPathComponent("rules.txt")
        try Data([0x41, 0x20, 0x3D, 0x3E, 0x20, 0xFF, 0xFE, 0x0A]).write(to: file)
        settings.setTerminologyRulesFile(file)

        XCTAssertTrue(settings.terminologyNormalizerForJob().isEmpty)
        XCTAssertEqual(settings.terminologyRulesValidation, .fileUnavailable)
    }

    func testAFileOverTheSizeLimitAppliesNoRules() throws {
        let rule = "Aster => Astor\n"
        let oversized = String(repeating: rule, count: TerminologyNormalizer.maximumRulesTextBytes / rule.utf8.count + 1)
        try settings.setTerminologyRulesFile(makeRulesFile(contents: oversized))

        XCTAssertTrue(settings.terminologyNormalizerForJob().isEmpty)
        XCTAssertEqual(settings.terminologyRulesValidation.message, "Terminology rules are too large to apply.")
        XCTAssertEqual(settings.terminologyRulesFileContents, "")
    }

    /// The 200-rule limit is the normalizer's own, so a file hits it exactly as
    /// the text area does.
    func testAFileKeepsTheRuleCountLimit() throws {
        let rules = (0 ... TerminologyNormalizer.maximumRuleCount)
            .map { index in "Term\(index) => variant\(index)" }
            .joined(separator: "\n")
        try settings.setTerminologyRulesFile(makeRulesFile(contents: rules))

        _ = settings.terminologyNormalizerForJob()

        XCTAssertEqual(
            settings.terminologyRulesValidation.message,
            "200 active terminology rules. 1 invalid line was ignored.",
        )
    }

    func testAFileThatBecomesReadableAgainAppliesItsRulesAtTheNextJob() throws {
        let file = try makeRulesFile(contents: "Aster => Astor\n")
        settings.setTerminologyRulesFile(file)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(settings.terminologyNormalizerForJob().isEmpty)

        try "Aster => Astor\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(settings.terminologyNormalizerForJob().normalize("Astor"), "Aster")
        XCTAssertEqual(settings.terminologyRulesValidation.message, "1 active terminology rule.")
    }

    private func makeRulesFile(contents: String) throws -> URL {
        let file = try makeTempDirectory(prefix: "terminology-rules").appendingPathComponent("rules.txt")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
