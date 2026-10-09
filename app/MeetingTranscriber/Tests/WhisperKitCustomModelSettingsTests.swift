import Foundation
@testable import MeetingTranscriber
import XCTest

/// A custom WhisperKit model (another Hugging Face repository, or a folder on disk)
/// is chosen in Settings and resolved into the variant and origin the engine loads.
/// These tests pin that resolution and its persistence; the engine side is in
/// `WhisperKitEngineModelOriginTests`.
final class WhisperKitCustomModelSettingsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite — see AppSettingsTests for why.
    override func setUp() {
        super.setUp()
        testSuiteName = "WhisperKitCustomModelSettingsTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
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

    /// Lay out a model folder the way the Hub downloader writes a variant.
    /// `omitting` drops one relative path.
    private func writeModelFolder(named name: String, omitting omitted: String? = nil) throws -> URL {
        let folder = try makeTempDirectory(prefix: "wk-custom").appendingPathComponent(name, isDirectory: true)
        var files = WhisperKitLocalSnapshot.requiredBundles.flatMap { bundle in
            WhisperKitLocalSnapshot.requiredFiles.map { "\(bundle).mlmodelc/\($0)" }
        }
        files += WhisperKitLocalSnapshot.requiredTokenizerFiles
        for relative in files where relative != omitted {
            let url = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return folder
    }

    // MARK: - Defaults

    func testCustomModelIsOffByDefaultAndTheStockVariantIsSelected() {
        XCTAssertFalse(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(settings.whisperKitCustomRepo, "")
        XCTAssertEqual(settings.whisperKitCustomVariant, "")
        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "")
        XCTAssertEqual(
            settings.whisperKitModelSelection,
            WhisperKitModelSelection(variant: "openai_whisper-large-v3-v20240930_turbo", origin: .stock),
        )
        XCTAssertEqual(settings.whisperKitCustomModelValidation, .notConfigured)
    }

    // MARK: - Persistence

    func testRepositoryAndVariantPersist() {
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"

        let reloaded = AppSettings(defaults: defaults)

        XCTAssertTrue(reloaded.whisperKitCustomModelEnabled)
        XCTAssertEqual(reloaded.whisperKitCustomRepo, "spert/flix-swissgerman-whisperkit")
        XCTAssertEqual(reloaded.whisperKitCustomVariant, "flix-swissgerman-large-v3_8bit")
        XCTAssertEqual(
            reloaded.whisperKitModelSelection,
            WhisperKitModelSelection(
                variant: "flix-swissgerman-large-v3_8bit",
                origin: .hub(repoID: "spert/flix-swissgerman-whisperkit"),
            ),
        )
    }

    func testChosenFolderPersistsWithItsBookmark() throws {
        let folder = try writeModelFolder(named: "my-finetune_8bit")

        settings.setWhisperKitCustomModelFolder(folder)

        let bookmark = try XCTUnwrap(settings.whisperKitCustomModelFolderBookmark)
        XCTAssertEqual(defaults.data(forKey: "whisperKitCustomModelFolderBookmark"), bookmark)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.whisperKitCustomModelFolderPath, folder.path)
        XCTAssertEqual(reloaded.whisperKitCustomModelFolderBookmark, bookmark)
    }

    /// A bookmark is tied to the URL it was made for; keeping it after another path
    /// was typed would load a folder the field no longer shows.
    func testTypedFolderPathDropsTheBookmark() throws {
        try settings.setWhisperKitCustomModelFolder(writeModelFolder(named: "picked"))
        XCTAssertNotNil(settings.whisperKitCustomModelFolderBookmark)

        settings.setWhisperKitCustomModelFolderPath("/tmp/typed-model")

        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "/tmp/typed-model")
        XCTAssertNil(settings.whisperKitCustomModelFolderBookmark)
        XCTAssertNil(defaults.data(forKey: "whisperKitCustomModelFolderBookmark"))
    }

    // MARK: - Resolution

    /// Turning the custom model off must restore stock behaviour exactly, whatever
    /// is still typed in its fields.
    func testDisabledCustomModelIgnoresItsFields() {
        settings.whisperKitModel = "openai_whisper-small"
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"

        XCTAssertEqual(
            settings.whisperKitModelSelection,
            WhisperKitModelSelection(variant: "openai_whisper-small", origin: .stock),
        )
    }

    func testFolderTakesPrecedenceOverTheRepositoryAndNamesTheVariant() throws {
        let folder = try writeModelFolder(named: "flix-swissgerman-large-v3_8bit")
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "someone/else"
        settings.whisperKitCustomVariant = "other"
        settings.setWhisperKitCustomModelFolder(folder)

        let selection = settings.whisperKitModelSelection

        XCTAssertEqual(selection.variant, "flix-swissgerman-large-v3_8bit")
        XCTAssertEqual(
            selection.origin,
            .localFolder(path: folder.path, bookmark: settings.whisperKitCustomModelFolderBookmark),
        )
    }

    func testRepositoryFieldsAreTrimmed() {
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = " spert/flix-swissgerman-whisperkit "
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit "

        XCTAssertEqual(
            settings.whisperKitModelSelection,
            WhisperKitModelSelection(
                variant: "flix-swissgerman-large-v3_8bit",
                origin: .hub(repoID: "spert/flix-swissgerman-whisperkit"),
            ),
        )
    }

    /// A half-typed repository must not reach the engine: every keystroke is synced,
    /// and a failed load there would cost the next recording its transcript.
    func testUnfinishedCustomModelFallsBackToTheStockVariant() {
        settings.whisperKitModel = "openai_whisper-base"
        settings.whisperKitCustomModelEnabled = true
        let stock = WhisperKitModelSelection(variant: "openai_whisper-base", origin: .stock)

        XCTAssertEqual(settings.whisperKitModelSelection, stock, "nothing entered")

        settings.whisperKitCustomRepo = "spert"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        XCTAssertEqual(settings.whisperKitModelSelection, stock, "repository without an owner")

        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = ""
        XCTAssertEqual(settings.whisperKitModelSelection, stock, "no variant")
    }

    /// The variant becomes a path component under the download cache and a glob for
    /// the downloader, so anything that could leave the repository folder is refused.
    func testVariantMustBeASingleFolderName() {
        for variant in ["..", "a/b", "large*", "with space", "../../etc"] {
            XCTAssertFalse(AppSettings.isValidVariant(variant), variant)
        }
        for variant in ["openai_whisper-large-v3-v20240930_turbo", "flix-swissgerman-large-v3_8bit", "distil.v3"] {
            XCTAssertTrue(AppSettings.isValidVariant(variant), variant)
        }
    }

    func testRepositoryMustBeOwnerSlashName() {
        for repoID in ["", "spert", "/flix", "spert/", "a/b/c", "spert/../x", "spe rt/flix"] {
            XCTAssertFalse(AppSettings.isValidRepoID(repoID), repoID)
        }
        XCTAssertTrue(AppSettings.isValidRepoID("spert/flix-swissgerman-whisperkit"))
        XCTAssertTrue(AppSettings.isValidRepoID("argmaxinc/whisperkit-coreml"))
    }

    // MARK: - Validation

    func testValidationDescribesTheRepositoryFields() {
        settings.whisperKitCustomRepo = "spert"
        XCTAssertEqual(settings.whisperKitCustomModelValidation, .invalidRepository)

        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        XCTAssertEqual(settings.whisperKitCustomModelValidation, .invalidVariant)

        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        XCTAssertEqual(
            settings.whisperKitCustomModelValidation,
            .repository(repoID: "spert/flix-swissgerman-whisperkit", variant: "flix-swissgerman-large-v3_8bit"),
        )
    }

    func testCompleteFolderValidates() throws {
        try settings.setWhisperKitCustomModelFolder(writeModelFolder(named: "complete"))

        XCTAssertEqual(settings.whisperKitCustomModelValidation, .folderReady)
    }

    /// The load-bearing negative case: a folder without its tokenizer would make
    /// WhisperKit fetch one from the Hub, which a picked folder must never need.
    func testFolderWithoutTokenizerIsReportedAsIncomplete() throws {
        try settings.setWhisperKitCustomModelFolder(writeModelFolder(named: "no-tokenizer", omitting: "tokenizer.json"))

        XCTAssertEqual(settings.whisperKitCustomModelValidation, .folder(.folderIncomplete(missing: "tokenizer.json")))
        XCTAssertEqual(settings.whisperKitCustomModelValidation.message, "Model folder is missing tokenizer.json.")
    }

    func testFolderWithoutAnEncoderIsReportedAsIncomplete() throws {
        try settings.setWhisperKitCustomModelFolder(
            writeModelFolder(named: "no-encoder", omitting: "AudioEncoder.mlmodelc/weights/weight.bin"),
        )

        XCTAssertEqual(
            settings.whisperKitCustomModelValidation,
            .folder(.folderIncomplete(missing: "AudioEncoder.mlmodelc/weights/weight.bin")),
        )
    }

    func testMissingFolderIsReportedAsUnavailable() {
        settings.setWhisperKitCustomModelFolderPath("/nonexistent/\(UUID().uuidString)")

        XCTAssertEqual(settings.whisperKitCustomModelValidation, .folder(.folderUnavailable))
    }

    func testValidationIsRecomputedOnLaunch() throws {
        try settings.setWhisperKitCustomModelFolder(writeModelFolder(named: "relaunch", omitting: "tokenizer_config.json"))

        XCTAssertEqual(
            AppSettings(defaults: defaults).whisperKitCustomModelValidation,
            .folder(.folderIncomplete(missing: "tokenizer_config.json")),
        )
    }
}
