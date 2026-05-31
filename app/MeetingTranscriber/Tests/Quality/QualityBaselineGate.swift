import Foundation

/// Format a metric value for human-readable gate output (notes + summaries).
private func qualityMetricString(_ value: Double) -> String {
    String(format: "%.4f", value)
}

/// Human-readable row label (`engine/fixture [variant]`) shared by gate notes
/// and regression summaries so the two never drift.
private func qualityRowLabel(engine: String, fixture: String, modelVariant: String?) -> String {
    "\(engine)/\(fixture)\(modelVariant.map { " [\($0)]" } ?? "")"
}

/// One blessed data point in the committed `quality-baseline.json`. The slim
/// counterpart to `QualityResult`: only the fields the gate compares on, none
/// of the volatile ones (`timestamp`, `durationSeconds`, `appVersion`,
/// breakdowns) so re-blessing produces a clean, reviewable diff.
struct QualityBaselineEntry: Codable, Equatable {
    let engine: String
    let fixture: String
    let modelVariant: String?
    let wer: Double?
    let der: Double?
}

/// Which metric a regression is about.
enum QualityMetric: String, Equatable {
    case wer
    case der
}

/// How much a metric may regress before the gate fails. The effective
/// allowance for a row is `max(absolute, relativeFraction * baseline)`:
/// the absolute floor keeps low-baseline metrics (e.g. Sortformer DER ~0.06)
/// honest, while the proportional term gives high-baseline metrics (e.g.
/// offline DER ~0.6) room for the larger absolute jitter they naturally show.
/// Both absorb the small CoreML/ANE run-to-run variance on GitHub-hosted
/// runners. Conservative by default; tighten once observed variance is known.
struct QualityTolerance: Equatable {
    /// Minimum allowed regression regardless of baseline magnitude.
    let absolute: Double
    /// Extra allowance as a fraction of the baseline value.
    let relativeFraction: Double

    static let `default` = Self(absolute: 0.03, relativeFraction: 0.20)

    /// Effective absolute allowance for a given baseline value.
    func allowance(forBaseline baseline: Double) -> Double {
        max(absolute, relativeFraction * baseline)
    }
}

/// A single metric that regressed beyond tolerance (or disappeared).
struct QualityRegression: Equatable {
    let engine: String
    let fixture: String
    let modelVariant: String?
    let metric: QualityMetric
    let baseline: Double
    /// `nil` when the current run produced the row but dropped the metric.
    let current: Double?
    let tolerance: Double

    var summary: String {
        let label = qualityRowLabel(engine: engine, fixture: fixture, modelVariant: modelVariant)
        guard let current else {
            return "\(label) \(metric.rawValue): measurement disappeared (baseline \(qualityMetricString(baseline)))"
        }
        let delta = current - baseline
        return "\(label) \(metric.rawValue): \(qualityMetricString(baseline)) → \(qualityMetricString(current)) "
            + "(+\(qualityMetricString(delta)) > tol \(qualityMetricString(tolerance)))"
    }
}

/// Outcome of comparing a fresh `quality-results.json` against the committed
/// baseline. Only `regressions` fail the gate; `notes` are informational
/// (improvements, new/unbaselined rows, rows missing from the current run).
struct QualityGateReport: Equatable {
    let regressions: [QualityRegression]
    let notes: [String]
    var passed: Bool {
        regressions.isEmpty
    }
}

/// Pure comparison logic for the quality regression gate plus the thin file-IO
/// wrapper the CI step uses. Lives in the test target — it is CI/test
/// infrastructure, never linked into the app.
enum QualityBaselineGate {
    private struct Key: Hashable {
        let engine: String
        let fixture: String
        let modelVariant: String?
    }

    /// A decrease smaller than this is treated as stable, not an improvement —
    /// it's below the baseline's 4-decimal rounding granularity, so the current
    /// full-precision value dipping a hair under the rounded baseline is noise.
    private static let improvementEpsilon = 0.001

    static func compare(
        baseline: [QualityBaselineEntry],
        current: [QualityResult],
        tolerance: QualityTolerance = .default,
    ) -> QualityGateReport {
        // Index the current run by key; a duplicate key keeps the later row.
        var currentByKey: [Key: QualityResult] = [:]
        for row in current {
            currentByKey[Key(engine: row.engine, fixture: row.fixture, modelVariant: row.modelVariant)] = row
        }
        let baselineKeys = Set(baseline.map { Key(engine: $0.engine, fixture: $0.fixture, modelVariant: $0.modelVariant) })

        var regressions: [QualityRegression] = []
        var notes: [String] = []

        for entry in baseline {
            let key = Key(engine: entry.engine, fixture: entry.fixture, modelVariant: entry.modelVariant)
            guard let row = currentByKey[key] else {
                notes.append("missing from current run: \(label(key))")
                continue
            }
            let metrics: [(QualityMetric, Double?, Double?)] = [
                (.wer, entry.wer, row.wer),
                (.der, entry.der, row.der),
            ]
            for (metric, base, cur) in metrics {
                switch evaluate(metric, baseline: base, current: cur, entry: entry, tolerance: tolerance) {
                case let .regression(regression): regressions.append(regression)
                case let .improvement(note): notes.append(note)
                case .ok: break
                }
            }
        }

        for row in current {
            let key = Key(engine: row.engine, fixture: row.fixture, modelVariant: row.modelVariant)
            guard !baselineKeys.contains(key) else { continue }
            notes.append("unbaselined (no baseline entry): \(label(key)) — bless to start tracking it")
        }

        return QualityGateReport(regressions: regressions, notes: notes.sorted())
    }

    /// Decode both files and compare. Throws if either file is missing or malformed.
    static func loadAndCompare(
        baselineURL: URL,
        resultsURL: URL,
        tolerance: QualityTolerance = .default,
    ) throws -> QualityGateReport {
        let baseline = try JSONDecoder().decode([QualityBaselineEntry].self, from: Data(contentsOf: baselineURL))
        let current = try JSONDecoder().decode([QualityResult].self, from: Data(contentsOf: resultsURL))
        return compare(baseline: baseline, current: current, tolerance: tolerance)
    }

    /// Committed baseline: `quality-baseline.json` in the shared quality
    /// fixtures dir (reused from `GroundTruth`). `QUALITY_BASELINE_PATH`
    /// overrides it.
    static var committedBaselineURL: URL {
        if let override = ProcessInfo.processInfo.environment["QUALITY_BASELINE_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return GroundTruth.qualityFixturesDir.appendingPathComponent("quality-baseline.json")
    }

    // MARK: - Helpers

    private enum MetricOutcome {
        case regression(QualityRegression)
        case improvement(String)
        case ok
    }

    /// Pure verdict for one metric of one baseline row. Returns `.ok` when the
    /// baseline doesn't track this metric or the current value is within
    /// tolerance, `.regression` when it exceeded tolerance or disappeared, and
    /// `.improvement` when it dropped meaningfully below the baseline.
    private static func evaluate(
        _ metric: QualityMetric,
        baseline: Double?,
        current: Double?,
        entry: QualityBaselineEntry,
        tolerance: QualityTolerance,
    ) -> MetricOutcome {
        guard let baseline else { return .ok } // baseline doesn't track this metric for this row
        let allowance = tolerance.allowance(forBaseline: baseline)
        guard let current else {
            return .regression(.init(
                engine: entry.engine, fixture: entry.fixture, modelVariant: entry.modelVariant,
                metric: metric, baseline: baseline, current: nil, tolerance: allowance,
            ))
        }
        let delta = current - baseline
        if delta > allowance {
            return .regression(.init(
                engine: entry.engine, fixture: entry.fixture, modelVariant: entry.modelVariant,
                metric: metric, baseline: baseline, current: current, tolerance: allowance,
            ))
        }
        if delta < -improvementEpsilon {
            let label = qualityRowLabel(engine: entry.engine, fixture: entry.fixture, modelVariant: entry.modelVariant)
            return .improvement("improvement: \(label) \(metric.rawValue) "
                + "\(qualityMetricString(baseline)) → \(qualityMetricString(current))")
        }
        return .ok
    }

    private static func label(_ key: Key) -> String {
        qualityRowLabel(engine: key.engine, fixture: key.fixture, modelVariant: key.modelVariant)
    }
}
