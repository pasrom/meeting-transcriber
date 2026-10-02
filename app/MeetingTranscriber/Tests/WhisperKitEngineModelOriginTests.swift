@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// A custom WhisperKit model differs from a stock one only in where its files come
/// from, so the engine carries that origin next to the variant name. These tests pin
/// that the origin reaches the model source and counts as part of the model's
/// identity. Nothing here touches the network or CoreML.
@MainActor
final class WhisperKitEngineModelOriginTests: XCTestCase {
    private let swissGerman = WhisperKitModelOrigin.hub(repoID: "spert/flix-swissgerman-whisperkit")

    /// A WhisperKit instance that loads nothing, as in `WhisperKitEngineModelSourceTests`.
    private func makeIdlePipe() async throws -> WhisperKit {
        try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
    }

    /// Install a source that loads every model from `folder` and records the origin
    /// each load resolved its source for.
    private func installOriginRecordingSource(on engine: WhisperKitEngine, folder: URL) async throws -> () -> [WhisperKitModelOrigin] {
        let pipe = try await makeIdlePipe()
        var origins: [WhisperKitModelOrigin] = []
        engine.installModelSourceForTesting { origin in
            origins.append(origin)
            return WhisperKitModelSource(
                locateLocal: { _ in folder },
                download: { _, _ in throw URLError(.networkConnectionLost) },
                makePipe: { _, _ in pipe },
            )
        }
        return { origins }
    }

    func testTheEngineStartsOnTheStockRepository() {
        XCTAssertEqual(WhisperKitEngine().modelOrigin, .stock)
        XCTAssertEqual(WhisperKitModelOrigin.stock, .hub(repoID: "argmaxinc/whisperkit-coreml"))
    }

    func testLoadResolvesItsSourceForTheRequestedOrigin() async throws {
        let engine = WhisperKitEngine()
        let origins = try await installOriginRecordingSource(on: engine, folder: makeTempDirectory(prefix: "wk-local"))
        engine.applyModelVariant("flix-swissgerman-large-v3_8bit", origin: swissGerman)

        await engine.loadModel()

        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(origins(), [swissGerman], "The custom repository must be the one the model is resolved in")
    }

    /// A fine-tune usually keeps its base model's folder name, so the same variant
    /// from another repository is a different model and must not keep the old pipe.
    func testChangingOnlyTheOriginDropsTheLoadedModel() async throws {
        let engine = WhisperKitEngine()
        let origins = try await installOriginRecordingSource(on: engine, folder: makeTempDirectory(prefix: "wk-local"))
        engine.applyModelVariant("openai_whisper-large-v3")
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Precondition: the stock model is loaded")

        engine.applyModelVariant("openai_whisper-large-v3", origin: swissGerman)

        XCTAssertEqual(engine.modelState, .unloaded, "The stock pipe must not serve the custom model")
        await engine.loadModel()
        XCTAssertEqual(origins(), [.stock, swissGerman])
    }

    /// Switching back to the stock picker entry must reach the engine as well: a
    /// variant-only call means the stock repository, not "keep the origin".
    func testAVariantOnlyChangeReturnsToTheStockRepository() {
        let engine = WhisperKitEngine()
        engine.applyModelVariant("flix-swissgerman-large-v3_8bit", origin: swissGerman)

        engine.applyModelVariant("openai_whisper-small")

        XCTAssertEqual(engine.modelVariant, "openai_whisper-small")
        XCTAssertEqual(engine.modelOrigin, .stock)
    }

    /// The mid-load reconcile compares the origin too: a load that finishes after the
    /// user switched to another repository must not be adopted as the current model.
    func testAnOriginChangeMidLoadIsFollowed() async throws {
        let engine = WhisperKitEngine()
        let folder = try makeTempDirectory(prefix: "wk-local")
        let pipe = try await makeIdlePipe()
        var built: [WhisperKitModelOrigin] = []
        let swissGerman = swissGerman
        engine.installModelSourceForTesting { origin in
            WhisperKitModelSource(
                locateLocal: { _ in folder },
                download: { _, _ in throw URLError(.networkConnectionLost) },
                makePipe: { _, _ in
                    built.append(origin)
                    if origin == .stock {
                        engine.applyModelVariant(engine.modelVariant, origin: swissGerman)
                    }
                    return pipe
                },
            )
        }

        await engine.loadModel()

        XCTAssertEqual(built, [.stock, swissGerman], "The superseded stock load must be followed by the custom one")
        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(engine.modelOrigin, swissGerman)
    }

    // MARK: - Production source for a picked folder

    private func writeCompleteModel(in folder: URL, omitting omitted: String? = nil) throws {
        var files = WhisperKitLocalSnapshot.requiredBundles.flatMap { bundle in
            WhisperKitLocalSnapshot.requiredFiles.map { "\(bundle).mlmodelc/\($0)" }
        }
        files += WhisperKitLocalSnapshot.requiredTokenizerFiles
        for relative in files where relative != omitted {
            let url = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    func testAPickedFolderIsLoadedInPlace() throws {
        let folder = try makeTempDirectory(prefix: "wk-folder")
        try writeCompleteModel(in: folder)
        let source = WhisperKitModelSource.production(for: .localFolder(path: folder.path, bookmark: nil))

        XCTAssertEqual(source.locateLocal(folder.lastPathComponent)?.path, folder.path)
    }

    /// There is nothing to download a picked folder from, so the download step must
    /// fail with what the folder lacks: that is the reason the engine logs.
    func testAnIncompleteFolderFailsWithWhatIsMissing() async throws {
        let folder = try makeTempDirectory(prefix: "wk-folder")
        try writeCompleteModel(in: folder, omitting: "TextDecoder.mlmodelc/model.mil")
        let source = WhisperKitModelSource.production(for: .localFolder(path: folder.path, bookmark: nil))

        XCTAssertNil(source.locateLocal(folder.lastPathComponent))
        do {
            _ = try await source.download(folder.lastPathComponent) { _ in }
            XCTFail("A picked folder must never be downloaded")
        } catch {
            XCTAssertEqual(error as? WhisperKitModelError, .folderIncomplete(missing: "TextDecoder.mlmodelc/model.mil"))
        }
    }

    func testAMissingFolderFailsAsUnavailable() async {
        let source = WhisperKitModelSource.production(
            for: .localFolder(path: "/nonexistent/\(UUID().uuidString)/model", bookmark: nil),
        )

        XCTAssertNil(source.locateLocal("model"))
        do {
            _ = try await source.download("model") { _ in }
            XCTFail("A picked folder must never be downloaded")
        } catch {
            XCTAssertEqual(error as? WhisperKitModelError, .folderUnavailable)
        }
    }
}
