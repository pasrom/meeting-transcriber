@testable import MeetingTranscriber
import XCTest

@MainActor
final class QualityResultsTests: XCTestCase {
    func test_appendCollectsRowsInOrder() {
        QualityResultsWriter.shared.reset()
        let writer = QualityResultsWriter.shared
        writer.append(makeRow(engine: "whisperKit", fixture: "two_speakers_de", wer: 0.05))
        writer.append(makeRow(engine: "parakeet", fixture: "two_speakers_de", wer: 0.07))
        XCTAssertEqual(writer.collectedRows.count, 2)
        XCTAssertEqual(writer.collectedRows[0].engine, "whisperKit")
        XCTAssertEqual(writer.collectedRows[1].engine, "parakeet")
    }

    func test_flushWritesValidJSONToOverridePath() throws {
        QualityResultsWriter.shared.reset()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quality-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        setenv("QUALITY_RESULTS_PATH", tmp.path, 1)
        defer { unsetenv("QUALITY_RESULTS_PATH") }

        QualityResultsWriter.shared.append(
            makeRow(engine: "whisperKit", fixture: "two_speakers_de", wer: 0.05),
        )
        let written = try QualityResultsWriter.shared.flush()
        XCTAssertEqual(written.path, tmp.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let decoded = try JSONDecoder().decode(
            [QualityResult].self,
            from: Data(contentsOf: tmp),
        )
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].engine, "whisperKit")
        XCTAssertEqual(decoded[0].wer, 0.05)
    }

    private func makeRow(engine: String, fixture: String, wer: Double) -> QualityResult {
        QualityResult(
            engine: engine,
            fixture: fixture,
            modelVariant: nil,
            wer: wer,
            der: nil,
            werBreakdown: nil,
            derBreakdown: nil,
            appVersion: "test",
            timestamp: "2026-05-08T00:00:00Z",
            durationSeconds: 1.0,
        )
    }
}
