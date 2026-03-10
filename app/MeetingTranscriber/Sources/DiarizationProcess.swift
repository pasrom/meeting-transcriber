import Foundation

/// Result from diarization.
struct DiarizationResult {
    struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
    }

    let segments: [Segment]
    let speakingTimes: [String: TimeInterval]
    let autoNames: [String: String]
    var embeddings: [String: [Float]]?
}

/// Abstraction for diarization, enabling mock injection in tests.
protocol DiarizationProvider {
    var isAvailable: Bool { get }
    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult
}

/// Speaker assignment utilities.
enum DiarizationProcess {
    /// Assign speaker labels to transcript segments by maximum temporal overlap.
    /// Uses `autoNames` to replace raw labels (e.g. "SPEAKER_0") with human names.
    /// When no overlap exists, falls back to the nearest diarization segment by gap distance.
    static func assignSpeakers(
        transcript: [TimestampedSegment],
        diarization: DiarizationResult
    ) -> [TimestampedSegment] {
        transcript.map { seg in
            var best = seg
            var bestOverlap: TimeInterval = 0

            for dSeg in diarization.segments {
                let overlapStart = max(seg.start, dSeg.start)
                let overlapEnd = min(seg.end, dSeg.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best.speaker = diarization.autoNames[dSeg.speaker] ?? dSeg.speaker
                }
            }

            // Fallback: find nearest diarization segment by gap distance
            if bestOverlap == 0 {
                var nearestGap: TimeInterval = .infinity
                for dSeg in diarization.segments {
                    let gap: TimeInterval
                    if seg.end <= dSeg.start {
                        gap = dSeg.start - seg.end
                    } else if seg.start >= dSeg.end {
                        gap = seg.start - dSeg.end
                    } else {
                        gap = 0
                    }
                    if gap < nearestGap {
                        nearestGap = gap
                        best.speaker = diarization.autoNames[dSeg.speaker] ?? dSeg.speaker
                    }
                }
            }

            if best.speaker.isEmpty {
                best.speaker = "UNKNOWN"
            }
            return best
        }
    }

    /// Identify which diarization speaker corresponds to the mic user
    /// by computing temporal overlap between mic segments and each diarization speaker.
    /// Returns the speaker label if overlap ratio > threshold, else nil.
    static func identifyMicSpeaker(
        micSegments: [TimestampedSegment],
        diarization: DiarizationResult,
        overlapThreshold: Double = 0.3
    ) -> String? {
        let totalMicTime = micSegments.reduce(0.0) { $0 + ($1.end - $1.start) }
        guard totalMicTime > 0 else { return nil }

        // Sum overlap per diarization speaker
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for dSeg in diarization.segments {
            for mic in micSegments {
                let overlapStart = max(mic.start, dSeg.start)
                let overlapEnd = min(mic.end, dSeg.end)
                let overlap = max(0, overlapEnd - overlapStart)
                if overlap > 0 {
                    overlapBySpeaker[dSeg.speaker, default: 0] += overlap
                }
            }
        }

        guard let (bestSpeaker, bestOverlap) = overlapBySpeaker.max(by: { $0.value < $1.value })
        else { return nil }

        let ratio = bestOverlap / totalMicTime
        return ratio > overlapThreshold ? bestSpeaker : nil
    }

    /// Hybrid speaker assignment for dual-source recordings.
    /// Mic segments keep micLabel. App ("Remote") segments get diarization speaker names,
    /// excluding the mic speaker.
    static func assignSpeakersHybrid(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        diarization: DiarizationResult,
        micSpeakerID: String?,
        micLabel: String
    ) -> [TimestampedSegment] {
        // Mic segments keep their label unchanged
        let labeledMic = micSegments.map { seg in
            var s = seg
            s.speaker = micLabel
            return s
        }

        // App segments: find best overlapping diarization speaker, skip micSpeakerID
        let labeledApp = appSegments.map { seg in
            var best = seg
            var bestOverlap: TimeInterval = 0

            for dSeg in diarization.segments {
                // Skip the mic speaker — they shouldn't appear on the app track
                if dSeg.speaker == micSpeakerID { continue }

                let overlapStart = max(seg.start, dSeg.start)
                let overlapEnd = min(seg.end, dSeg.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best.speaker = diarization.autoNames[dSeg.speaker] ?? dSeg.speaker
                }
            }

            // No overlap: keep "Remote" (we know they're remote, not unknown)
            if best.speaker.isEmpty || bestOverlap == 0 {
                best.speaker = "Remote"
            }
            return best
        }

        // Merge sorted by start time
        var result = labeledMic + labeledApp
        result.sort { $0.start < $1.start }
        return result
    }
}

enum DiarizationError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Diarization not available"
        }
    }
}
