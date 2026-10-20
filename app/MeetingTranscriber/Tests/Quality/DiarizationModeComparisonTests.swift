import Foundation
@testable import MeetingTranscriber
import XCTest

/// Opt-in side-by-side run of every diarization mode on one labelled
/// recording, through `FluidDiarizer.run` exactly as the pipeline calls it.
/// Skipped unless `MEETINGTRANSCRIBER_DIARIZATION_TRUTH` names a ground-truth
/// JSON in the quality-fixture shape (`GroundTruth`), with its `audio` file
/// next to it. Meant for recordings that cannot be committed as fixtures.
///
/// Prints one line per mode: speakers found against the reference count, the
/// overlap-aware DER, the share of reference turns whose dominant hypothesis
/// speaker maps to the right person, the share of overlapped reference time in
/// which the hypothesis also has two speakers, how many speakers got an
/// embedding, and the runtime of a cold run (model download and load included)
/// and of a second, warm run; then a second line with the labels each
/// reference speaker was given. Asserts only that each mode produced segments:
/// the numbers are for reading, the gated DER bounds live in
/// `FluidDiarizerQualityTests`.
@MainActor
final class DiarizationModeComparisonTests: XCTestCase {
    func testCompareModesOnLabelledRecording() async throws {
        let path = ProcessInfo.processInfo.environment["MEETINGTRANSCRIBER_DIARIZATION_TRUTH"] ?? ""
        try XCTSkipIf(path.isEmpty, "Set MEETINGTRANSCRIBER_DIARIZATION_TRUTH to a ground-truth JSON")
        let truthURL = URL(fileURLWithPath: path)
        let truth = try JSONDecoder().decode(GroundTruth.self, from: Data(contentsOf: truthURL))
        let audioURL = truthURL.deletingLastPathComponent().appendingPathComponent(truth.audio)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: audioURL.path), "Audio missing: \(audioURL.path)")

        let reference = truth.diarizationTurns
        let referenceSpeakers = Set(reference.map(\.speaker)).count

        for mode in DiarizerMode.allCases {
            let diarizer = FluidDiarizer(mode: mode)
            let coldStart = Date()
            _ = try await diarizer.run(audioPath: audioURL, numSpeakers: nil, meetingTitle: truth.fixture)
            let cold = Date().timeIntervalSince(coldStart)
            let warmStart = Date()
            let result = try await diarizer.run(audioPath: audioURL, numSpeakers: nil, meetingTitle: truth.fixture)
            let warm = Date().timeIntervalSince(warmStart)

            let hypothesis = result.segments.map { segment in
                DERCalculator.Turn(speaker: segment.speaker, start: segment.start, end: segment.end)
            }
            let der = DERCalculator.derBreakdown(reference: reference, hypothesis: hypothesis)
            let turns = Self.turnAccuracy(reference: reference, hypothesis: hypothesis)
            let overlap = Self.overlapRecall(reference: reference, hypothesis: hypothesis)
            let line = [
                "[DiarizationComparison] mode=\(mode.rawValue)",
                "speakers=\(Set(hypothesis.map(\.speaker)).count)/\(referenceSpeakers)",
                String(
                    format: "der=%.3f (miss %.2f s, fa %.2f s, conf %.2f s)",
                    der.der,
                    der.missedSpeech,
                    der.falseAlarm,
                    der.speakerConfusion,
                ),
                "turns=\(turns.correct)/\(turns.total)",
                overlap.map { String(format: "overlapRecall=%.2f", $0) } ?? "overlapRecall=n/a",
                "embeddings=\(result.embeddings?.count ?? 0)",
                String(format: "cold=%.1f s warm=%.1f s audio=%.1f s", cold, warm, truth.duration),
            ].joined(separator: " ")
            print(line)
            print("[DiarizationComparison] mode=\(mode.rawValue) heard as: \(Self.heardAs(reference: reference, hypothesis: hypothesis))")
            XCTAssertFalse(result.segments.isEmpty, "\(mode.rawValue) produced no segments")
        }
    }

    // MARK: - Scoring

    /// Seconds two turn lists share, per (hypothesis, reference) speaker pair.
    private static func overlapSeconds(
        _ hypothesis: [DERCalculator.Turn], _ reference: [DERCalculator.Turn],
    ) -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for hyp in hypothesis {
            for ref in reference {
                let shared = min(hyp.end, ref.end) - max(hyp.start, ref.start)
                if shared > 0 { result[hyp.speaker, default: [:]][ref.speaker, default: 0] += shared }
            }
        }
        return result
    }

    /// One-to-one hypothesis → reference mapping with the most shared time,
    /// by exhaustive search (at most eight hypothesis speakers). One-to-one so
    /// that a speaker split in two costs the turns of the smaller half.
    private static func bestMapping(_ overlap: [String: [String: Double]], references: [String]) -> [String: String] {
        let hyps = overlap.keys.sorted()
        var best: (score: Double, mapping: [String: String]) = (-1, [:])
        func search(_ index: Int, _ used: Set<String>, _ score: Double, _ mapping: [String: String]) {
            guard index < hyps.count else {
                if score > best.score { best = (score, mapping) }
                return
            }
            let hyp = hyps[index]
            search(index + 1, used, score, mapping)
            for ref in references where !used.contains(ref) {
                var next = mapping
                next[hyp] = ref
                search(index + 1, used.union([ref]), score + (overlap[hyp]?[ref] ?? 0), next)
            }
        }
        search(0, [], 0, [:])
        return best.mapping
    }

    /// Reference turns whose dominant hypothesis speaker (most time inside the
    /// turn) maps to the turn's speaker. A turn nobody was detected in counts
    /// as wrong.
    private static func turnAccuracy(
        reference: [DERCalculator.Turn], hypothesis: [DERCalculator.Turn],
    ) -> (correct: Int, total: Int) {
        let mapping = bestMapping(
            overlapSeconds(hypothesis, reference), references: Array(Set(reference.map(\.speaker))).sorted(),
        )
        var correct = 0
        for turn in reference {
            var inside: [String: Double] = [:]
            for hyp in hypothesis {
                let shared = min(hyp.end, turn.end) - max(hyp.start, turn.start)
                if shared > 0 { inside[hyp.speaker, default: 0] += shared }
            }
            guard let dominant = inside.max(by: { $0.value < $1.value })?.key else { continue }
            if mapping[dominant] == turn.speaker { correct += 1 }
        }
        return (correct, reference.count)
    }

    /// Per reference speaker, the hypothesis labels their speech was given,
    /// by share of their time: `A: SPEAKER_0 91%, SPEAKER_1 9%`. Shows which
    /// voices a mode merged or split, which the aggregate numbers hide.
    private static func heardAs(reference: [DERCalculator.Turn], hypothesis: [DERCalculator.Turn]) -> String {
        let overlap = overlapSeconds(hypothesis, reference)
        return Set(reference.map(\.speaker)).sorted().map { ref in
            let total = reference.filter { $0.speaker == ref }.reduce(0.0) { $0 + $1.end - $1.start }
            let parts = overlap.compactMap { hyp, refs in refs[ref].map { (hyp, $0) } }
                .sorted { $0.1 > $1.1 }
                .map { String(format: "%@ %.0f%%", $0.0, 100 * $0.1 / max(total, 1e-9)) }
            return "\(ref): " + (parts.isEmpty ? "nothing" : parts.joined(separator: ", "))
        }.joined(separator: "; ")
    }

    /// Share of the reference's overlapped time (two or more speakers) in
    /// which the hypothesis also has two or more speakers, on a 10 ms grid.
    /// Nil when the reference has no overlap.
    private static func overlapRecall(reference: [DERCalculator.Turn], hypothesis: [DERCalculator.Turn]) -> Double? {
        let end = (reference + hypothesis).map(\.end).max() ?? 0
        let step = 0.01
        var overlapped = 0
        var detected = 0
        var time = 0.0
        while time < end {
            let refCount = Set(reference.filter { $0.start <= time && time < $0.end }.map(\.speaker)).count
            if refCount >= 2 {
                overlapped += 1
                let hypCount = Set(hypothesis.filter { $0.start <= time && time < $0.end }.map(\.speaker)).count
                if hypCount >= 2 { detected += 1 }
            }
            time += step
        }
        return overlapped == 0 ? nil : Double(detected) / Double(overlapped)
    }
}
