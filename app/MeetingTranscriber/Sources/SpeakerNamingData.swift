import Foundation

// The speaker-naming value types live in their own file (split out of
// `PipelineQueue.swift`), but stay nested under `PipelineQueue` so the many
// existing references (`PipelineQueue.SpeakerNamingData`, its `.Segment`, and
// `PipelineQueue.SpeakerNamingResult`) across the UI, RPC, persistence, and
// tests keep resolving unchanged. The Codable wire format is namespace-
// independent (no type name is encoded), so the move is purely organisational.
extension PipelineQueue {
    /// Data for the speaker naming popup.
    struct SpeakerNamingData: Codable {
        let jobID: UUID
        let meetingTitle: String
        let mapping: [String: String] // label → auto-matched name or label
        let speakingTimes: [String: TimeInterval]
        let embeddings: [String: [Float]]
        let audioPath: URL? // 16kHz mix for playback
        let segments: [Segment] // for extracting speaker snippets
        let participants: [String] // Teams participant names as suggestions
        let isDualSource: Bool
        /// Per-instance identity for SwiftUI `.onChange` change-detection.
        /// Late re-diarization can produce a `mapping`/`speakingTimes` set
        /// that compares byte-equal to the previous run (same speaker count,
        /// same matcher output) — without a fresh marker, the naming view's
        /// per-presentation reset never fires and consecutive Re-run clicks
        /// are silently swallowed by the `completedJobID` guard. Excluded
        /// from CodingKeys so disk reloads regenerate it.
        var revision: UUID = .init()

        private enum CodingKeys: String, CodingKey {
            case jobID, meetingTitle, mapping, speakingTimes, embeddings,
                 audioPath, segments, participants, isDualSource
        }

        struct Segment: Codable {
            let start: TimeInterval
            let end: TimeInterval
            let speaker: String
        }
    }

    /// Result from the speaker naming popup.
    enum SpeakerNamingResult {
        case confirmed([String: String]) // user confirmed with mapping
        case rerun(Int) // re-run diarization with N speakers (current mode)
        /// Re-run diarization with a different mode AND speaker count. New in
        /// the Mode↔Count-coupling follow-up: lets the user recover from a
        /// wrong-mode-at-recording-time (e.g. Sortformer's 4-speaker cap hit
        /// on a 6-speaker meeting) without leaving the naming dialog.
        case rerunWithMode(DiarizerMode, Int)
        case skipped // user skipped
    }
}
