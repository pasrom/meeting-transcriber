import Foundation

/// Diarization Error Rate calculator (pyannote-style).
///
/// DER = (missed_speech + false_alarm + speaker_confusion) / total_reference_speech
///
/// where speakers are matched optimally between reference and hypothesis to
/// maximise overlap before counting confusion. Optimal mapping is brute-forced
/// over all permutations — fine for the small speaker counts (<=10) we hit in
/// real meetings.
///
/// Overlap is not modelled: at most one speaker is active at any instant in
/// each timeline. If a turn list contains overlap, later turns silently win
/// for the overlapping interval — diarisation engines we test against don't
/// emit overlap anyway.
enum DERCalculator {
    struct Turn: Equatable {
        let speaker: String
        let start: Double
        let end: Double
    }

    struct Breakdown: Equatable {
        let missedSpeech: Double
        let falseAlarm: Double
        let speakerConfusion: Double
        let totalReference: Double
        let der: Double
    }

    static func der(reference: [Turn], hypothesis: [Turn]) -> Double {
        derBreakdown(reference: reference, hypothesis: hypothesis).der
    }

    static func derBreakdown(reference: [Turn], hypothesis: [Turn]) -> Breakdown {
        let intervals = sliceTimeline(reference: reference, hypothesis: hypothesis)
        let totalRef = intervals
            .filter { $0.refSpeaker != nil }
            .reduce(0.0) { $0 + $1.duration }

        if totalRef == 0 {
            let der = hypothesis.isEmpty ? 0.0 : 1.0
            let fa = intervals.reduce(0.0) { $0 + ($1.hypSpeaker == nil ? 0 : $1.duration) }
            return Breakdown(
                missedSpeech: 0,
                falseAlarm: fa,
                speakerConfusion: 0,
                totalReference: 0,
                der: der,
            )
        }

        let refSpeakers = Array(Set(reference.map(\.speaker))).sorted()
        let hypSpeakers = Array(Set(hypothesis.map(\.speaker))).sorted()

        // overlap[h][r] = total time hyp speaker h overlaps ref speaker r
        var overlap = Array(
            repeating: Array(repeating: 0.0, count: refSpeakers.count),
            count: hypSpeakers.count,
        )
        for interval in intervals {
            guard let r = interval.refSpeaker, let h = interval.hypSpeaker,
                  let ri = refSpeakers.firstIndex(of: r),
                  let hi = hypSpeakers.firstIndex(of: h)
            else { continue }
            overlap[hi][ri] += interval.duration
        }

        let mapping = bestMapping(
            refSpeakers: refSpeakers,
            hypSpeakers: hypSpeakers,
            overlap: overlap,
        )

        var missed = 0.0
        var falseAlarm = 0.0
        var confusion = 0.0
        for interval in intervals {
            switch (interval.refSpeaker, interval.hypSpeaker) {
            case (nil, nil):
                continue

            case (.some, nil):
                missed += interval.duration

            case (nil, .some):
                falseAlarm += interval.duration

            case let (refSpeaker?, hypSpeaker?):
                if mapping[hypSpeaker] == refSpeaker {
                    continue
                }
                confusion += interval.duration
            }
        }

        let totalErrors = missed + falseAlarm + confusion
        return Breakdown(
            missedSpeech: missed,
            falseAlarm: falseAlarm,
            speakerConfusion: confusion,
            totalReference: totalRef,
            der: totalErrors / totalRef,
        )
    }

    // MARK: - Internals

    private struct Interval {
        let start: Double
        let end: Double
        let refSpeaker: String?
        let hypSpeaker: String?
        var duration: Double {
            end - start
        }
    }

    /// Slice reference + hypothesis timelines into micro-intervals at every
    /// turn boundary. Within each micro-interval, ref and hyp speakers are
    /// constant.
    private static func sliceTimeline(
        reference: [Turn],
        hypothesis: [Turn],
    ) -> [Interval] {
        var boundaries = Set<Double>()
        for t in reference {
            boundaries.insert(t.start); boundaries.insert(t.end)
        }
        for t in hypothesis {
            boundaries.insert(t.start); boundaries.insert(t.end)
        }
        let sorted = boundaries.sorted()
        guard sorted.count >= 2 else { return [] }

        var result: [Interval] = []
        for i in 0 ..< (sorted.count - 1) {
            let s = sorted[i]
            let e = sorted[i + 1]
            guard e > s else { continue }
            let mid = (s + e) / 2
            result.append(
                Interval(
                    start: s,
                    end: e,
                    refSpeaker: speaker(at: mid, in: reference),
                    hypSpeaker: speaker(at: mid, in: hypothesis),
                ),
            )
        }
        return result
    }

    private static func speaker(at t: Double, in turns: [Turn]) -> String? {
        for turn in turns where turn.start <= t && t < turn.end {
            return turn.speaker
        }
        return nil
    }

    /// Pick the hyp→ref assignment maximising total overlap. Brute-force
    /// recursion over all valid one-to-one mappings; bounded by speaker count.
    private static func bestMapping(
        refSpeakers: [String],
        hypSpeakers: [String],
        overlap: [[Double]],
    ) -> [String: String] {
        var best: [String: String] = [:]
        var bestScore = -1.0

        func recurse(hypIdx: Int, used: Set<Int>, current: [String: String], score: Double) {
            if hypIdx == hypSpeakers.count {
                if score > bestScore {
                    bestScore = score
                    best = current
                }
                return
            }
            // Hyp may stay unmapped (e.g. when M > N or the speaker has zero
            // overlap with any reference turn).
            recurse(hypIdx: hypIdx + 1, used: used, current: current, score: score)
            for r in 0 ..< refSpeakers.count where !used.contains(r) {
                var next = current
                next[hypSpeakers[hypIdx]] = refSpeakers[r]
                recurse(
                    hypIdx: hypIdx + 1,
                    used: used.union([r]),
                    current: next,
                    score: score + overlap[hypIdx][r],
                )
            }
        }
        recurse(hypIdx: 0, used: [], current: [:], score: 0)
        return best
    }
}
