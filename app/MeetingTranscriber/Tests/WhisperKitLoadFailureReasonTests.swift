@testable import ArgmaxCore
@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// A failed model load used to leave the user with "WhisperKit model not loaded"
/// and the actual reason in a redacted log line. The engine now keeps one
/// user-facing sentence for the last failed load; these tests pin where it comes
/// from, that it is path-free, and that it reaches the job error. Nothing here
/// touches the network or CoreML.
@MainActor
final class WhisperKitLoadFailureReasonTests: XCTestCase {
    private let pickedFolder = WhisperKitModelOrigin.localFolder(path: "/picked/finetune", bookmark: nil)
    private let swissGerman = WhisperKitModelOrigin.hub(repoID: "spert/flix-swissgerman-whisperkit")

    private func makeIdlePipe() async throws -> WhisperKit {
        try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
    }

    /// A source with no local copy whose download fails with `error`.
    private func installFailingSource(on engine: WhisperKitEngine, error: any Error) {
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in throw error },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))
    }

    // MARK: - Plumbing through the engine

    /// The sentence is the one the Settings validation line already shows for the
    /// same folder, so the user reads one wording in both places.
    func testAFailedLoadKeepsTheFolderProblemAsItsReason() async {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: pickedFolder)
        installFailingSource(on: engine, error: WhisperKitModelError.folderIncomplete(missing: "tokenizer.json"))

        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertEqual(
            engine.loadFailureReason,
            WhisperKitCustomModelValidation.folder(.folderIncomplete(missing: "tokenizer.json")).message,
        )
    }

    func testTheReasonReachesTheJobError() async {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: pickedFolder)
        installFailingSource(on: engine, error: WhisperKitModelError.folderIncomplete(missing: "tokenizer.json"))

        do {
            _ = try await engine.transcribeSegments(audioPath: fixtureURL())
            XCTFail("Transcribing without a model must throw")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "WhisperKit model not loaded: Model folder is missing tokenizer.json.",
                "The prefix is what existing consumers match on; the reason follows it",
            )
        }
    }

    func testASuccessfulLoadClearsTheReason() async throws {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: pickedFolder)
        installFailingSource(on: engine, error: WhisperKitModelError.folderUnavailable)
        await engine.loadModel()
        XCTAssertNotNil(engine.loadFailureReason, "Precondition: the first load failed")

        let pipe = try await makeIdlePipe()
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in URL(fileURLWithPath: "/picked/finetune") },
            download: { _, _ in throw URLError(.networkConnectionLost) },
            makePipe: { _, _ in pipe },
        ))
        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertNil(engine.loadFailureReason)
    }

    /// The reason describes the last attempt, so it is gone the moment a new one
    /// starts: a stale sentence next to "Downloading model..." would read as the
    /// download having failed already.
    func testANewAttemptClearsTheReasonBeforeItRuns() async {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: pickedFolder)
        installFailingSource(on: engine, error: WhisperKitModelError.folderUnavailable)
        await engine.loadModel()
        XCTAssertNotNil(engine.loadFailureReason, "Precondition: the first load failed")

        var reasonDuringDownload: String? = "unread"
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                reasonDuringDownload = engine.loadFailureReason
                throw WhisperKitModelError.folderNotLoadable
            },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))
        await engine.loadModel()

        XCTAssertNil(reasonDuringDownload)
        XCTAssertEqual(engine.loadFailureReason, WhisperKitModelError.folderNotLoadable.message)
    }

    func testChangingTheModelClearsTheReason() async {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: pickedFolder)
        installFailingSource(on: engine, error: WhisperKitModelError.folderUnavailable)
        await engine.loadModel()
        XCTAssertNotNil(engine.loadFailureReason, "Precondition: the first load failed")

        engine.applyModelVariant("openai_whisper-small")

        XCTAssertNil(engine.loadFailureReason)
    }

    /// A failed reload keeps the installed pipe, and that pipe is the requested
    /// model: any change of model drops it. The engine keeps working and reports
    /// `.loaded`, so a reason next to it would put "Model ready" and a red error
    /// about the same model side by side.
    func testAFailedReloadBesideAWorkingModelLeavesNoReason() async throws {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: pickedFolder)
        let pipe = try await makeIdlePipe()
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in URL(fileURLWithPath: "/picked/finetune") },
            download: { _, _ in throw URLError(.networkConnectionLost) },
            makePipe: { _, _ in pipe },
        ))
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Precondition: the model is loaded")

        installFailingSource(on: engine, error: WhisperKitModelError.folderUnavailable)
        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .loaded, "Precondition: the failed reload kept the working model")
        XCTAssertNil(engine.loadFailureReason)
    }

    /// A load that fails after the model was changed failed for the old model, so
    /// its sentence must not be kept for the new one. The retry for the new model
    /// would clear it again, but only if it runs: a cancelled owner stops the chain
    /// before that, and the user would then read why the previous model failed
    /// next to the model they just picked.
    func testAFailureForAModelNoLongerRequestedLeavesNoReason() async {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("finetune", origin: pickedFolder)
        var load: Task<Void, Never>?
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: { _ in nil },
            download: { _, _ in
                // The user picks another model while this one is loading, and the
                // owner of the load goes away before the chain can retry.
                engine.applyModelVariant("openai_whisper-small")
                load?.cancel()
                throw WhisperKitModelError.folderUnavailable
            },
            makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
        ))

        let task = Task { @MainActor in await engine.loadModel() }
        load = task
        await task.value

        XCTAssertEqual(engine.modelVariant, "openai_whisper-small", "Precondition: the model changed mid-load")
        XCTAssertNil(engine.loadFailureReason, "The failure belongs to the model that is no longer requested")
    }

    // MARK: - Wording

    private func reason(for error: any Error, origin: WhisperKitModelOrigin? = nil, variant: String = "finetune") -> String {
        WhisperKitLoadFailureReason.describe(error, variant: variant, origin: origin ?? pickedFolder)
    }

    /// WhisperKit's own message for a missing file carries the full path, and with
    /// it the account name; the sentence shown to the user must not.
    func testWhisperKitsPathBearingMessageIsNotShown() {
        let path = "/Users/someone/Library/Containers/x/finetune/TextDecoder.mlmodelc"

        let sentence = reason(for: WhisperError.modelsUnavailable("Model file not found at \(path)"))

        XCTAssertFalse(sentence.contains("/Users"), sentence)
        XCTAssertFalse(sentence.contains("someone"), sentence)
        XCTAssertFalse(sentence.isEmpty)
    }

    func testAnUnknownVariantNamesTheRepositoryAndTheVariant() {
        let sentence = reason(
            for: WhisperError.modelsUnavailable("No models found matching \"*finetune/*\" in Repo(id: \"spert/x\", type: models)"),
            origin: swissGerman,
        )

        XCTAssertEqual(sentence, "spert/flix-swissgerman-whisperkit has no folder named finetune.")
    }

    /// WhisperKit searches `*<variant>/*` and, when more than one folder matches,
    /// once more with `*openai*<variant>/*`; this is its message when that second
    /// search still matches more than one folder.
    func testAnAmbiguousVariantAsksForTheFullFolderName() {
        let sentence = reason(
            for: WhisperError.modelsUnavailable("Multiple models found matching \"*openai*large-v3/*\" in Repo(id: \"spert/x\", type: models)"),
            origin: swissGerman,
            variant: "large-v3",
        )

        XCTAssertEqual(
            sentence,
            "spert/flix-swissgerman-whisperkit has more than one folder ending in large-v3; the variant must be the full folder name.",
        )
    }

    /// WhisperKit reads the token only from these two environment variables, so
    /// the sentence names them; a 401 and a 403 are the same rejection to it.
    func testARejectedTokenIsExplained() {
        for statusCode in [401, 403] {
            let error = Hub.HubClientError.authorizationRequired(statusCode: statusCode)

            XCTAssertEqual(
                reason(for: error, origin: swissGerman),
                "Hugging Face refused the request: the repository may be private, "
                    + "or the token set in HF_TOKEN or HUGGING_FACE_HUB_TOKEN is no longer valid.",
            )
        }
    }

    /// A Hub error whose text is path-free is shown as it is, because "offline"
    /// and "404" need different fixes.
    func testAPathFreeHubErrorIsShownVerbatim() {
        let error = Hub.HubClientError.downloadError("The Internet connection appears to be offline.")

        let sentence = reason(for: error, origin: swissGerman)

        XCTAssertTrue(sentence.contains(error.localizedDescription), sentence)
    }

    /// A Hub file-system error wraps a Cocoa error, whose description names the
    /// file; it is collapsed like any other error that may carry a path.
    func testAHubFileSystemErrorIsNotShownVerbatim() {
        let cocoa = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/Users/someone/x"])

        let sentence = reason(for: Hub.HubClientError.fileSystemError(cocoa), origin: swissGerman)

        XCTAssertFalse(sentence.contains("someone"), sentence)
    }

    func testTheFolderProblemIsWordedAsInSettings() {
        XCTAssertEqual(reason(for: WhisperKitModelError.folderUnavailable), WhisperKitModelError.folderUnavailable.message)
    }
}
