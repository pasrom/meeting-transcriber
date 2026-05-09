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
            makeRow(
                engine: "whisperKit",
                fixture: "two_speakers_de",
                wer: 0.05,
                modelVariant: "large-v3-turbo",
                der: 0.06,
                werBreakdown: QualityResult.WERBreakdown(
                    substitutions: 1, deletions: 2, insertions: 3, referenceLength: 28,
                ),
                derBreakdown: QualityResult.DERBreakdown(
                    missedSpeech: 0.1, falseAlarm: 0.2, speakerConfusion: 0.3, totalReference: 10.0,
                ),
            ),
        )
        let written = try QualityResultsWriter.shared.flush()
        XCTAssertEqual(written.path, tmp.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let decoded = try JSONDecoder().decode(
            [QualityResult].self,
            from: Data(contentsOf: tmp),
        )
        XCTAssertEqual(decoded.count, 1)
        let row = decoded[0]
        XCTAssertEqual(row.engine, "whisperKit")
        XCTAssertEqual(row.fixture, "two_speakers_de")
        XCTAssertEqual(row.modelVariant, "large-v3-turbo")
        XCTAssertEqual(row.wer, 0.05)
        XCTAssertEqual(row.der, 0.06)
        XCTAssertEqual(row.appVersion, "test")
        XCTAssertEqual(row.timestamp, "2026-05-08T00:00:00Z")
        XCTAssertEqual(row.durationSeconds, 1.0)
        XCTAssertEqual(row.werBreakdown?.substitutions, 1)
        XCTAssertEqual(row.werBreakdown?.deletions, 2)
        XCTAssertEqual(row.werBreakdown?.insertions, 3)
        XCTAssertEqual(row.werBreakdown?.referenceLength, 28)
        XCTAssertEqual(row.derBreakdown?.missedSpeech, 0.1)
        XCTAssertEqual(row.derBreakdown?.falseAlarm, 0.2)
        XCTAssertEqual(row.derBreakdown?.speakerConfusion, 0.3)
        XCTAssertEqual(row.derBreakdown?.totalReference, 10.0)
    }

    private func makeRow(
        engine: String,
        fixture: String,
        wer: Double,
        modelVariant: String? = nil,
        der: Double? = nil,
        werBreakdown: QualityResult.WERBreakdown? = nil,
        derBreakdown: QualityResult.DERBreakdown? = nil,
    ) -> QualityResult {
        QualityResult(
            engine: engine,
            fixture: fixture,
            modelVariant: modelVariant,
            wer: wer,
            der: der,
            werBreakdown: werBreakdown,
            derBreakdown: derBreakdown,
            appVersion: "test",
            timestamp: "2026-05-08T00:00:00Z",
            durationSeconds: 1.0,
        )
    }
}
