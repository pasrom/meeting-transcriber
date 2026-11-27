@testable import MeetingTranscriber
import ViewInspector
import XCTest

final class GigaAMTests: XCTestCase {
    @MainActor
    func testSelectingGigaAMRoutesToTheRussianEngine() throws {
        let settings = try makeIsolatedSettings()
        let controller = EngineController(settings: settings)
        settings.whisperLanguage = "en"
        settings.parakeetLanguage = "de"
        settings.transcriptionEngine = .gigaAM

        XCTAssertIdentical(controller.activeTranscriptionEngine, controller.gigaAMEngine)
        XCTAssertEqual(settings.activeEngineLanguageOrNil, "ru")

        let view = TranscriptionSettingsView(
            settings: settings, whisperKitEngine: controller.whisperKit,
            parakeetEngine: controller.parakeetEngine, gigaAMEngine: controller.gigaAMEngine,
        )
        XCTAssertNoThrow(try view.inspect().find(text: "Russian (fixed)"))
    }

    func testCTCSeparatesRepeatedTokensWhenABlankIntervenes() {
        let pieces = GigaAMModel.collapse([1, 1, 256, 1, 0, 2], vocabulary: ["<unk>", "▁да", "."])
        XCTAssertEqual(GigaAMSegmentation.text(pieces), "да да.")
        XCTAssertEqual(pieces.map(\.firstFrame), [0, 3, 5])
        XCTAssertEqual(pieces.map(\.endFrame), [2, 4, 6])
    }

    func testSegmentTimesIncludeChunkOffsetAndStayInTheRecording() {
        let pieces: [GigaAMModel.Piece] = [
            .init(text: "▁Привет.", firstFrame: 1, endFrame: 3),
            .init(text: "▁Тест.", firstFrame: 4, endFrame: 7),
        ]
        let segments = GigaAMSegmentation.segments(pieces, offset: 400_000, length: 4000)
        XCTAssertEqual(segments.map(\.text), ["Привет.", "Тест."])
        XCTAssertEqual(segments[0].start, 25.04, accuracy: 0.0001)
        XCTAssertEqual(segments[1].end, 25.25, accuracy: 0.0001)
    }

    func testFullWindowCutsAtAQuietSpotWhileTheFinalWindowKeepsItsTail() {
        let end = GigaAMModel.maxSamples
        var samples = [Float](repeating: 0.5, count: end)
        samples.replaceSubrange((end - 3200) ..< (end - 1600), with: repeatElement(0, count: 1600))
        XCTAssertEqual(GigaAMSegmentation.chunkLength(samples, hasMore: true), end - 2400)
        XCTAssertEqual(GigaAMSegmentation.chunkLength(samples, hasMore: false), end)
    }
}
