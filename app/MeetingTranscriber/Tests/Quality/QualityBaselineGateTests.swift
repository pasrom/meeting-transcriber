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

    // MARK: - compare(): a row with no measurement fails, it is not a note

    /// Renamed and inverted. It used to assert that a baseline row with no
    /// counterpart is a note and the gate still passes, which is the behaviour
    /// that let a run measuring NOTHING report success. A note does not fail,
    /// and this gate is a required status check for moving a stable tag.
    func test_compare_missingFromCurrentRunFailsTheGate() {
        let report = QualityBaselineGate.compare(
            baseline: [
                entry(engine: "whisperKit", fixture: "two", wer: 0.20),
                entry(engine: "parakeet", fixture: "two", wer: 0.25),
            ],
            current: [],
        )

        XCTAssertFalse(report.passed, "a run that measured nothing must not pass")
        XCTAssertTrue(report.regressions.isEmpty, "nothing got worse; there is no number at all")
        // Two rows rather than one, and the count asserted rather than only
        // non-emptiness: a report that names the first missing row and stops
        // would satisfy every other assertion here.
        XCTAssertEqual(report.missing.count, 2)
        XCTAssertTrue(
            report.missing.contains { $0.contains("whisperKit") },
            "expected the missing rows to name each engine, got: \(report.missing)",
        )
        XCTAssertTrue(
            report.missing.contains { $0.contains("parakeet") },
            "expected the missing rows to name each engine, got: \(report.missing)",
        )
    }

    /// A partial miss: one row gone while the rest are fine still fails, and
    /// the failure says which row. The whole-run case is
    /// `test_compare_missingFromCurrentRunFailsTheGate`.
    func test_compare_singleMissingRowFailsAndNamesIt() {
        let report = QualityBaselineGate.compare(
            baseline: [
                entry(engine: "whisperKit", fixture: "two", wer: 0.20),
                entry(engine: "parakeet", fixture: "two", wer: 0.25),
            ],
            current: [result(engine: "whisperKit", fixture: "two", wer: 0.20)],
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.missing.count, 1)
        XCTAssertTrue(
            report.missing.contains { $0.contains("parakeet") },
            "the failure must name the row that produced no measurement, got: \(report.missing)",
        )
    }

    /// The control that stops the two above from passing for the wrong reason:
    /// with every row present and within tolerance, `missing` is empty and the
    /// gate passes.
    func test_compare_completeRunLeavesMissingEmpty() {
        let report = QualityBaselineGate.compare(
            baseline: [
                entry(engine: "whisperKit", fixture: "two", wer: 0.20),
                entry(engine: "parakeet", fixture: "two", wer: 0.25),
            ],
            current: [
                result(engine: "whisperKit", fixture: "two", wer: 0.20),
                result(engine: "parakeet", fixture: "two", wer: 0.25),
            ],
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.missing.isEmpty)
    }

    // MARK: - compare(): tolerance

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

    /// The baseline here is populated on purpose. It used to be empty, which
    /// made the assertion below true for two different reasons at once: the
    /// extra row really is only a note, and a comparison against nothing
    /// passed anyway. Only the first of those is this test's subject.
    func test_compare_unbaselinedCurrentEntryIsNoteNotRegression() {
        let report = QualityBaselineGate.compare(
            baseline: [entry(engine: "whisperKit", fixture: "two", wer: 0.20)],
            current: [
                result(engine: "whisperKit", fixture: "two", wer: 0.20),
                result(engine: "parakeet", fixture: "two", wer: 0.40),
            ],
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(
            report.notes.contains { $0.contains("parakeet") },
            "expected an unbaselined note mentioning the engine, got: \(report.notes)",
        )
    }

    // MARK: - compare(): an empty baseline compares nothing

    /// An empty baseline compares nothing and therefore proves nothing, but
    /// `regressions.isEmpty && missing.isEmpty` is true for it, so the gate
    /// used to pass. That is reachable without anyone acting in bad faith: the
    /// gate's own failure message says to re-bless, `bless_quality_baseline.sh`
    /// accepts a results file with zero rows, and re-blessing from a run that
    /// measured nothing writes `[]` and leaves a required check permanently
    /// and silently green.
    func test_compare_emptyBaselineFailsRatherThanComparingNothing() {
        let report = QualityBaselineGate.compare(baseline: [], current: [])
        XCTAssertFalse(report.passed, "an empty baseline compares nothing and must not read as a pass")
        XCTAssertEqual(report.baselineRowCount, 0)
    }

    /// The counterpart: a populated baseline still passes on a clean run, so
    /// the guard above refuses emptiness and nothing else.
    func test_compare_populatedBaselinePassesOnACleanRun() {
        let base = [entry(engine: "parakeet", fixture: "two_speakers_de", wer: 0.20)]
        let current = [result(engine: "parakeet", fixture: "two_speakers_de", wer: 0.20)]
        let report = QualityBaselineGate.compare(baseline: base, current: current)
        XCTAssertTrue(report.passed, "a real comparison with no regression must still pass")
        XCTAssertEqual(report.baselineRowCount, 1)
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

        // "tiny just missing" used to be a pass. It is the same hole one variant
        // wide: the row the baseline tracks produced no measurement, and the
        // gate is what would have to notice.
        XCTAssertFalse(report.passed, "the tiny variant produced no measurement")
        XCTAssertTrue(report.regressions.isEmpty, "turbo is within tolerance")
        XCTAssertTrue(
            report.missing.contains { $0.contains("tiny") },
            "expected the unmatched tiny variant to be reported missing, got: \(report.missing)",
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
        // Printed, not only asserted on. A missing row is the one failure mode
        // whose cause lies outside this comparison -- a fixture that did not
        // decode, a leg that died, an engine that never loaded -- so the log
        // has to name the rows before anyone can look for the reason.
        for key in report.missing {
            print("[quality-gate] NOT MEASURED: \(key)")
        }
        print("[quality-gate] compared against \(report.baselineRowCount) baseline row(s)")

        // Three failures with three different remedies. They used to share one
        // message, and it was the wrong one for two of them: telling an
        // operator to re-bless after a run that measured nothing is an
        // instruction to overwrite the baseline with the emptiness, which
        // turns this required check permanently green.
        XCTAssertGreaterThan(
            report.baselineRowCount,
            0,
            "The committed baseline has no rows, so this check compared nothing and cannot "
                + "report quality. Restore the baseline from history; do not re-bless.",
        )
        XCTAssertTrue(
            report.missing.isEmpty,
            "This run did not measure \(report.missing.count) baselined row(s), so their quality "
                + "is unknown rather than unchanged. Find out why the run skipped them and fix "
                + "that. Do NOT re-bless from this run: that would delete the rows from the "
                + "baseline and make their absence permanent.\n"
                + report.missing.joined(separator: "\n"),
        )
        XCTAssertTrue(
            report.regressions.isEmpty,
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
