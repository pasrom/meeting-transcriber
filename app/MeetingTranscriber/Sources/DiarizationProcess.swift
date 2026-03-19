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
    var embeddings: [String: [Float]]? // swiftlint:disable:this discouraged_optional_collection
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
        diarization: DiarizationResult,
    ) -> [TimestampedSegment] {
        // swiftlint:disable:next closure_body_length
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
                    let gap: TimeInterval = if seg.end <= dSeg.start {
                        dSeg.start - seg.end
                    } else if seg.start >= dSeg.end {
                        seg.start - dSeg.end
                    } else {
                        0
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

    // MARK: - Dual-Track Diarization

    /// Merge two separate diarization results (app + mic) into one,
    /// prefixing speaker IDs with `R_` (remote/app) and `M_` (mic/local).
    static func mergeDualTrackDiarization(
        appDiarization: DiarizationResult,
        micDiarization: DiarizationResult,
    ) -> DiarizationResult {
        // Prefix app segments with R_
        let appSegments = appDiarization.segments.map { seg in
            DiarizationResult.Segment(start: seg.start, end: seg.end, speaker: "R_\(seg.speaker)")
        }
        // Prefix mic segments with M_
        let micSegments = micDiarization.segments.map { seg in
            DiarizationResult.Segment(start: seg.start, end: seg.end, speaker: "M_\(seg.speaker)")
        }

        // Merge and sort by start time
        var allSegments = appSegments + micSegments
        allSegments.sort { $0.start < $1.start }

        // Merge speaking times with prefixed keys
        var speakingTimes: [String: TimeInterval] = [:]
        for (key, value) in appDiarization.speakingTimes {
            speakingTimes["R_\(key)"] = value
        }
        for (key, value) in micDiarization.speakingTimes {
            speakingTimes["M_\(key)"] = value
        }

        // Merge embeddings with prefixed keys
        var embeddings: [String: [Float]]? // swiftlint:disable:this discouraged_optional_collection
        if appDiarization.embeddings != nil || micDiarization.embeddings != nil {
            embeddings = [:]
            for (key, value) in appDiarization.embeddings ?? [:] {
                embeddings?["R_\(key)"] = value
            }
            for (key, value) in micDiarization.embeddings ?? [:] {
                embeddings?["M_\(key)"] = value
            }
        }

        // Merge autoNames with prefixed keys
        var autoNames: [String: String] = [:]
        for (key, value) in appDiarization.autoNames {
            autoNames["R_\(key)"] = value
        }
        for (key, value) in micDiarization.autoNames {
            autoNames["M_\(key)"] = value
        }

        return DiarizationResult(
            segments: allSegments,
            speakingTimes: speakingTimes,
            autoNames: autoNames,
            embeddings: embeddings,
        )
    }

    /// Merge consecutive segments from the same speaker into single blocks.
    /// Preserves the start timestamp of the first segment and end timestamp of the last.
    /// Text is joined with spaces.
    static func mergeConsecutiveSpeakers(
        _ segments: [TimestampedSegment],
    ) -> [TimestampedSegment] {
        guard var current = segments.first else { return [] }

        var merged: [TimestampedSegment] = []
        for seg in segments.dropFirst() {
            if seg.speaker == current.speaker {
                current = TimestampedSegment(
                    start: current.start,
                    end: seg.end,
                    text: "\(current.text) \(seg.text)",
                    speaker: current.speaker,
                )
            } else {
                merged.append(current)
                current = seg
            }
        }
        merged.append(current)
        return merged
    }

    /// Assign speakers using separate diarizations for app and mic tracks.
    /// App segments are matched against appDiarization, mic segments against micDiarization.
    static func assignSpeakersDualTrack(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        appDiarization: DiarizationResult,
        micDiarization: DiarizationResult,
    ) -> [TimestampedSegment] {
        let labeledApp = assignSpeakers(transcript: appSegments, diarization: appDiarization)
        let labeledMic = assignSpeakers(transcript: micSegments, diarization: micDiarization)

        var result = labeledApp + labeledMic
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
