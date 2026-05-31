@testable import MeetingTranscriber
import XCTest

/// Pure-logic + file-IO tests for the quality baseline gate. These run on every
/// `swift test` (no `RUN_QUALITY_TESTS` gate) because they exercise only the
/// comparison logic against synthetic rows — no models, no fixtures.
///
/// The one heavyweight, env-gated assertion (`test_qualityResultsMatchBaseline`)
/// lives at the bottom and skips unless the dedicated quality job set up the
/// results file.
final class QualityBaselineGateTests: XCTestCase {
    // MARK: - compare(): regressions

    func test_compare_flagsWERRegressionBeyondTolerance() {
        let baseline = [entry(engine: "whisperKit", fixture: "two", wer: 0.20)]
        let current = [result(engine: "whisperKit", fixture: "two", wer: 0.30)]

        let report = QualityBaselineGate.compare(
            baseline: baseline,
            current: current,
            tolerance: .init(absolute: 0.05, relativeFraction: 0),
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.regressions.count, 1)
        let r = try? XCTUnwrap(report.regressions.first)
        XCTAssertEqual(r?.metric, .wer)
        XCTAssertEqual(r?.engine, "whisperKit")
        XCTAssertEqual(r?.fixture, "two")
        XCTAssertEqual(r?.baseline, 0.20)
        XCTAssertEqual(r?.current, 0.30)
    }

    func test_compare_passesWithinTolerance() {
        let report = QualityBaselineGate.compare(
            baseline: [entry(engine: "whisperKit", fixture: "two", wer: 0.20)],
            current: [result(engine: "whisperKit", fixture: "two", wer: 0.24)],
            tolerance: .init(absolute: 0.05, relativeFraction: 0),
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.regressions.isEmpty)
    }

    func test_compare_improvementIsNotARegression() {
        let report = QualityBaselineGate.compare(
            baseline: [entry(engine: "whisperKit", fixture: "two", wer: 0.30)],
            current: [result(engine: "whisperKit", fixture: "two", wer: 0.20)],
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(
            report.notes.contains { $0.lowercased().contains("improv") },
            "expected an improvement note, got: \(report.notes)",
        )
    }

    func test_compare_disappearedMetricIsRegression() {
        // Baseline measured DER; current run produced the row but no DER value
        // (a broken diarizer test would do this). Losing a measurement must fail.
        let report = QualityBaselineGate.compare(
            baseline: [entry(engine: "fluidDiarizer.offline", fixture: "two", der: 0.50)],
            current: [result(engine: "fluidDiarizer.offline", fixture: "two")],
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.regressions.first?.metric, .der)
        XCTAssertNil(report.regressions.first?.current)
    }

    func test_relativeToleranceCatchesLowBaselineRegression() {
        // Sortformer-style low DER: a +0.04 jump on a 0.06 baseline is a large
        // relative regression that the old flat-0.05 tolerance waved through.
        let report = QualityBaselineGate.compare(
            baseline: [entry(engine: "fluidDiarizer.sortformer", fixture: "two", der: 0.06)],
            current: [result(engine: "fluidDiarizer.sortformer", fixture: "two", der: 0.10)],
            tolerance: .init(absolute: 0.03, relativeFraction: 0.20),
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.regressions.first?.metric, .der)
    }

    func test_relativeToleranceAllowsProportionalDriftOnHighBaseline() {
        // Offline DER ~0.60: a +0.10 absolute move is within the proportional
        // band (0.20 × 0.60 = 0.12), so it must not fail the gate.
        let report = QualityBaselineGate.compare(
            baseline: [entry(engine: "fluidDiarizer.offline", fixture: "two", der: 0.60)],
            current: [result(engine: "fluidDiarizer.offline", fixture: "two", der: 0.70)],
            tolerance: .init(absolute: 0.03, relativeFraction: 0.20),
        )

        XCTAssertTrue(report.passed)
    }

    // MARK: - compare(): structural mismatches are warnings, not failures

    func test_compare_unbaselinedCurrentEntryIsNoteNotRegression() {
        let report = QualityBaselineGate.compare(
            baseline: [],
            current: [result(engine: "parakeet", fixture: "two", wer: 0.40)],
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(
            report.notes.contains { $0.contains("parakeet") },
            "expected an unbaselined note mentioning the engine, got: \(report.notes)",
        )
    }

    func test_compare_missingFromCurrentRunIsNoteNotRegression() {
        let report = QualityBaselineGate.compare(
            baseline: [entry(engine: "whisperKit", fixture: "two", wer: 0.20)],
            current: [],
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(
            report.notes.contains { $0.contains("whisperKit") },
            "expected a missing-row note mentioning the engine, got: \(report.notes)",
        )
    }

    // MARK: - compare(): key discrimination + multi-metric

    func test_compare_keyIncludesModelVariant() {
        // Same engine+fixture, different model variant → distinct rows. A current
        // row for variant A must not satisfy the baseline for variant B.
        let baseline = [
            entry(engine: "whisperKit", fixture: "two", modelVariant: "turbo", wer: 0.20),
            entry(engine: "whisperKit", fixture: "two", modelVariant: "tiny", wer: 0.40),
        ]
        let current = [result(engine: "whisperKit", fixture: "two", modelVariant: "turbo", wer: 0.21)]

        let report = QualityBaselineGate.compare(baseline: baseline, current: current)

        XCTAssertTrue(report.passed, "turbo within tolerance, tiny just missing")
        XCTAssertTrue(
            report.notes.contains { $0.contains("tiny") },
            "expected the unmatched tiny variant to be reported missing, got: \(report.notes)",
        )
    }

    func test_compare_handlesWERandDERRowsIndependently() {
        let baseline = [
            entry(engine: "whisperKit", fixture: "two", wer: 0.20),
            entry(engine: "fluidDiarizer.offline", fixture: "two", der: 0.50),
        ]
        let current = [
            result(engine: "whisperKit", fixture: "two", wer: 0.21), // ok
            result(engine: "fluidDiarizer.offline", fixture: "two", der: 0.70), // regressed
        ]

        let report = QualityBaselineGate.compare(
            baseline: baseline,
            current: current,
            tolerance: .init(absolute: 0.05, relativeFraction: 0),
        )

        XCTAssertEqual(report.regressions.count, 1)
        XCTAssertEqual(report.regressions.first?.metric, .der)
        XCTAssertEqual(report.regressions.first?.engine, "fluidDiarizer.offline")
    }

    // MARK: - JSON decoding of the real wire shapes

    func test_baselineEntryDecodesSlimShapeWithOmittedKeys() throws {
        // The committed baseline omits nil keys (modelVariant / the unused metric).
        let json = """
        [
          { "engine": "parakeet", "fixture": "two_speakers_de", "wer": 0.4286 },
          { "engine": "whisperKit", "fixture": "two_speakers_de", "modelVariant": "turbo", "wer": 0.2857 },
          { "engine": "fluidDiarizer.offline", "fixture": "two_speakers_de", "der": 0.5325 }
        ]
        """
        let entries = try JSONDecoder().decode([QualityBaselineEntry].self, from: Data(json.utf8))

        XCTAssertEqual(entries.count, 3)
        XCTAssertNil(entries[0].modelVariant)
        XCTAssertEqual(entries[0].wer, 0.4286)
        XCTAssertNil(entries[0].der)
        XCTAssertEqual(entries[1].modelVariant, "turbo")
        XCTAssertEqual(entries[2].der, 0.5325)
    }

    func test_qualityResultArrayDecodesFromWriterOutput() throws {
        // Shape produced by QualityResultsWriter.flush() — nil keys omitted.
        let json = """
        [
          {
            "appVersion": "16.0", "durationSeconds": 1.6, "engine": "parakeet",
            "fixture": "two_speakers_de", "timestamp": "2026-05-31T20:01:14Z",
            "wer": 0.4286,
            "werBreakdown": { "deletions": 4, "insertions": 1, "referenceLength": 28, "substitutions": 7 }
          }
        ]
        """
        let rows = try JSONDecoder().decode([QualityResult].self, from: Data(json.utf8))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].engine, "parakeet")
        XCTAssertEqual(rows[0].wer, 0.4286)
        XCTAssertNil(rows[0].der)
        XCTAssertNil(rows[0].modelVariant)
    }

    // MARK: - loadAndCompare(): file IO

    func test_loadAndCompareReadsBothFilesAndDetectsRegression() throws {
        let dir = try makeTempDirectory(prefix: "quality-gate")
        let baselineURL = dir.appendingPathComponent("baseline.json")
        let resultsURL = dir.appendingPathComponent("results.json")

        try Data("""
        [ { "engine": "whisperKit", "fixture": "two", "modelVariant": "turbo", "wer": 0.20 } ]
        """.utf8).write(to: baselineURL)

        try Data("""
        [ {
          "appVersion": "dev", "durationSeconds": 1.0, "engine": "whisperKit",
          "fixture": "two", "modelVariant": "turbo", "timestamp": "t", "wer": 0.40
        } ]
        """.utf8).write(to: resultsURL)

        let report = try QualityBaselineGate.loadAndCompare(
            baselineURL: baselineURL,
            resultsURL: resultsURL,
            tolerance: .init(absolute: 0.05, relativeFraction: 0),
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.regressions.first?.metric, .wer)
    }

    func test_loadAndCompareThrowsWhenResultsFileMissing() throws {
        let dir = try makeTempDirectory(prefix: "quality-gate")
        let baselineURL = dir.appendingPathComponent("baseline.json")
        try Data("[]".utf8).write(to: baselineURL)

        XCTAssertThrowsError(
            try QualityBaselineGate.loadAndCompare(
                baselineURL: baselineURL,
                resultsURL: dir.appendingPathComponent("does-not-exist.json"),
            ),
        )
    }

    // MARK: - CI gate (env-gated, heavyweight)

    /// The actual regression gate the `quality-and-safety` workflow runs as a
    /// separate step after the measurement classes have flushed
    /// `QUALITY_RESULTS_PATH`. Skipped unless that job opted in, so a normal
    /// `swift test` never needs the results file to exist.
    func test_qualityResultsMatchBaseline() throws {
        try skipUnlessQualityRun()
        let resultsPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["QUALITY_RESULTS_PATH"],
            "QUALITY_RESULTS_PATH must be set for the gate (written by the measurement step)",
        )
        let report = try QualityBaselineGate.loadAndCompare(
            baselineURL: QualityBaselineGate.committedBaselineURL,
            resultsURL: URL(fileURLWithPath: resultsPath),
        )

        for note in report.notes {
            print("[quality-gate] note: \(note)")
        }
        for r in report.regressions {
            print("[quality-gate] REGRESSION: \(r.summary)")
        }

        XCTAssertTrue(
            report.passed,
            "Quality regressed vs the committed baseline. Re-bless with "
                + "scripts/bless_quality_baseline.sh once the change is intended.\n"
                + report.regressions.map(\.summary).joined(separator: "\n"),
        )
    }

    // MARK: - Builders

    private func entry(
        engine: String,
        fixture: String,
        modelVariant: String? = nil,
        wer: Double? = nil,
        der: Double? = nil,
    ) -> QualityBaselineEntry {
        QualityBaselineEntry(engine: engine, fixture: fixture, modelVariant: modelVariant, wer: wer, der: der)
    }

    private func result(
        engine: String,
        fixture: String,
        modelVariant: String? = nil,
        wer: Double? = nil,
        der: Double? = nil,
    ) -> QualityResult {
        QualityResult(
            engine: engine,
            fixture: fixture,
            modelVariant: modelVariant,
            wer: wer,
            der: der,
            werBreakdown: nil,
            derBreakdown: nil,
            appVersion: "dev",
            timestamp: "t",
            durationSeconds: 0,
        )
    }
}
