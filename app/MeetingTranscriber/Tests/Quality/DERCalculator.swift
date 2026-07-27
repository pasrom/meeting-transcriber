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
/// Overlap IS modelled, NIST-style: an instant carries a set of active speakers
/// on each side, the denominator counts reference speaker-time (so an instant
/// with two speakers talking counts twice), and per instant
/// `missed = max(0, |ref| - |hyp|)`, `falseAlarm = max(0, |hyp| - |ref|)`,
/// `confusion = min(|ref|, |hyp|) - correctly mapped`.
///
/// This degenerates to the plain single-speaker formula whenever BOTH sides
/// have at most one speaker active at a time. Note both: an overlap-free
/// reference is not sufficient, because an overlap-aware diarizer can report
/// two speakers where the reference has one, and that false alarm is exactly
/// what the collapsing version used to discard.
///
/// It matters because a real meeting runs roughly a third overlapping, and
/// collapsing that to one speaker per instant both understates the denominator
/// by nearly 30 % and inverts the incentive for the one mode whose whole point
/// is overlap awareness: Sortformer would score BETTER by losing the ability to
/// report simultaneous speakers.
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
        // Speaker-time, not wall-clock: an instant with two speakers active
        // contributes twice, so overlap a diarizer misses is charged in full.
        let totalRef = intervals.reduce(0.0) { $0 + $1.duration * Double($1.ref.count) }

        if totalRef == 0 {
            let der = hypothesis.isEmpty ? 0.0 : 1.0
            let fa = intervals.reduce(0.0) { $0 + $1.duration * Double($1.hyp.count) }
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
            for h in interval.hyp {
                guard let hi = hypSpeakers.firstIndex(of: h) else { continue }
                for r in interval.ref {
                    guard let ri = refSpeakers.firstIndex(of: r) else { continue }
                    overlap[hi][ri] += interval.duration
                }
            }
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
            let refCount = interval.ref.count
            let hypCount = interval.hyp.count
            if refCount == 0, hypCount == 0 { continue }

            // How many hypothesis speakers here map onto a reference speaker
            // that is genuinely active here. The mapping is one-to-one, so this
            // can never exceed min(refCount, hypCount).
            var correct = 0
            for hypSpeaker in interval.hyp {
                guard let mapped = mapping[hypSpeaker], interval.ref.contains(mapped) else { continue }
                correct += 1
            }

            missed += Double(max(0, refCount - hypCount)) * interval.duration
            falseAlarm += Double(max(0, hypCount - refCount)) * interval.duration
            confusion += Double(min(refCount, hypCount) - correct) * interval.duration
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
        let ref: Set<String>
        let hyp: Set<String>
        var duration: Double {
            end - start
        }
    }

    /// Slice reference + hypothesis timelines into micro-intervals at every
    /// turn boundary. Within each micro-interval, the set of active ref and hyp
    /// speakers is constant.
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
                    ref: speakers(at: mid, in: reference),
                    hyp: speakers(at: mid, in: hypothesis),
                ),
            )
        }
        return result
    }

    /// Every speaker active at `t`, not just the first turn that covers it.
    /// Returning a set is what makes simultaneous speakers visible to the
    /// metric; returning one speaker silently discarded them.
    private static func speakers(at t: Double, in turns: [Turn]) -> Set<String> {
        var active: Set<String> = []
        for turn in turns where turn.start <= t && t < turn.end {
            active.insert(turn.speaker)
        }
        return active
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
