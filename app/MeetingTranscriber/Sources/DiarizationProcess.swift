import Foundation
import os.log

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
                    best.speaker = dSeg.speaker
                }
            }

            if best.speaker.isEmpty {
                best.speaker = "UNKNOWN"
            }
            return best
        }
    }
}

enum DiarizationError: LocalizedError {
    case notAvailable
    case processFailed(Int, String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Diarization not available"
        case .processFailed(let code, let stderr):
            "Diarization failed (exit \(code))\(stderr.isEmpty ? "" : ": \(stderr.prefix(200))")"
        case .invalidOutput: "Failed to parse diarization output"
        }
    }
}
