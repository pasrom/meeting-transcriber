import Foundation
@testable import MeetingTranscriber
import XCTest

/// Opt-in check that a real custom WhisperKit model loads and transcribes through the
/// engine, the same way a recording would. Skipped unless pointed at a model:
///
/// - `MEETINGTRANSCRIBER_CUSTOM_WHISPERKIT_FOLDER`: a variant folder on disk. Loaded
///   in place, never downloaded.
/// - `MEETINGTRANSCRIBER_CUSTOM_WHISPERKIT_REPO` plus `..._VARIANT`: a Hugging Face
///   repository and variant folder. Downloaded into WhisperKit's cache on first use
///   (a large-v3 fine-tune is about 1.5 GB), loaded from there afterwards.
/// - `MEETINGTRANSCRIBER_CUSTOM_WHISPERKIT_AUDIO`, optional: the file to transcribe,
///   German fixture by default. Decoded with language `de`.
///
/// The transcript is printed, not compared: a fine-tune's wording is its own.
@MainActor
final class WhisperKitCustomModelSmokeTests: XCTestCase {
    private static let environmentPrefix = "MEETINGTRANSCRIBER_CUSTOM_WHISPERKIT_"

    private func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[Self.environmentPrefix + key].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func audioURL() throws -> URL {
        let url = environment("AUDIO").map { URL(fileURLWithPath: $0) } ?? fixtureURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Audio not found at \(url.path)")
        return url
    }

    private func transcribe(with engine: WhisperKitEngine, label: String) async throws {
        let audio = try audioURL()
        engine.language = "de"

        let loadStart = Date()
        await engine.loadModel()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        XCTAssertEqual(engine.modelState, .loaded, "The custom model must load")

        let transcribeStart = Date()
        let segments = try await engine.transcribeSegments(audioPath: audio)
        let transcribeSeconds = Date().timeIntervalSince(transcribeStart)

        XCTAssertFalse(segments.isEmpty, "The custom model must produce at least one segment")
        let text = segments.map(\.text).joined(separator: " ")
        XCTAssertFalse(text.contains("<|"), "Special tokens must be stripped: \(text)")
        print("[CustomWhisperKitSmoke] \(label) load=\(String(format: "%.1f", loadSeconds))s "
            + "transcribe=\(String(format: "%.1f", transcribeSeconds))s audio=\(audio.lastPathComponent)")
        print("[CustomWhisperKitSmoke] transcript: \(text)")
    }

    func testCustomModelFolderTranscribes() async throws {
        guard let path = environment("FOLDER") else {
            throw XCTSkip("Set \(Self.environmentPrefix)FOLDER to a WhisperKit model folder")
        }
        let folder = URL(fileURLWithPath: path)
        XCTAssertNil(WhisperKitLocalSnapshot.checkModelFolder(folder), "The folder must pass the same check Settings shows")

        let engine = WhisperKitEngine()
        engine.applyModelVariant(folder.lastPathComponent, origin: .localFolder(path: path, bookmark: nil))

        try await transcribe(with: engine, label: "folder=\(folder.lastPathComponent)")
    }

    func testCustomHubModelTranscribes() async throws {
        guard let repoID = environment("REPO"), let variant = environment("VARIANT") else {
            throw XCTSkip("Set \(Self.environmentPrefix)REPO and \(Self.environmentPrefix)VARIANT to a Hugging Face model")
        }
        let origin = WhisperKitModelOrigin.hub(repoID: repoID)
        // The production source, wrapped only to report whether the Hub was needed:
        // a second run against an already-fetched model must not download again.
        let production = WhisperKitModelSource.production(for: origin)
        let foundLocally = production.locateLocal(variant) != nil
        var downloaded = false
        let engine = WhisperKitEngine()
        engine.installModelSourceForTesting(WhisperKitModelSource(
            locateLocal: production.locateLocal,
            download: { variant, progress in
                downloaded = true
                return try await production.download(variant, progress)
            },
            makePipe: production.makePipe,
        ))
        engine.applyModelVariant(variant, origin: origin)

        try await transcribe(with: engine, label: "repo=\(repoID) variant=\(variant)")

        print("[CustomWhisperKitSmoke] foundLocallyBeforeLoad=\(foundLocally) downloaded=\(downloaded)")
        if foundLocally {
            XCTAssertFalse(downloaded, "An already-fetched custom model must load without the Hub (issue #736)")
        }
    }
}
