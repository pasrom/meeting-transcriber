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
        let audioPath: URL? // 16kHz mix; the sample's fallback (`sampleSources`)
        let segments: [Segment] // for extracting speaker snippets
        let participants: [String] // Teams participant names as suggestions
        let isDualSource: Bool
        /// The separate app and microphone tracks of a dual-source recording,
        /// so a speaker's sample can be played from their own track rather
        /// than the mix. Nil for single-source recordings and for naming data
        /// saved before this existed; playback then uses `audioPath`.
        var tracks: TrackAudio?
        /// Per-instance identity for SwiftUI `.onChange` change-detection.
        /// Late re-diarization can produce a `mapping`/`speakingTimes` set
        /// that compares byte-equal to the previous run (same speaker count,
        /// same matcher output) — without a fresh marker, the naming view's
        /// per-presentation reset never fires and consecutive Re-run clicks
        /// are silently swallowed by the dialog's answer gate (`NamingAnswerGate`). Excluded
        /// from CodingKeys so disk reloads regenerate it.
        var revision: UUID = .init()

        private enum CodingKeys: String, CodingKey {
            case jobID, meetingTitle, mapping, speakingTimes, embeddings,
                 audioPath, segments, participants, isDualSource, tracks
        }

        /// Where each track of a dual-source recording lies. `micDelay` is
        /// the offset the pipeline shifts the microphone's segments by onto
        /// the app (and mix) timeline, so a microphone sample is cut at the
        /// segment's time minus it.
        struct TrackAudio: Codable, Equatable {
            let app: URL
            let mic: URL
            let micDelay: TimeInterval

            /// The per-track files a dual-source job persists next to its mix
            /// (same slug) for late re-diarization. They live as long as the
            /// naming data does. Nil without the job's microphone delay, which
            /// the cut of a microphone sample needs.
            static func persisted(in outputDir: URL, slug: String, micDelay: TimeInterval?) -> Self? {
                guard let micDelay else { return nil }
                let recordings = outputDir.appendingPathComponent("recordings")
                return Self(
                    app: recordings.appendingPathComponent("\(slug)_app_16k.wav"),
                    mic: recordings.appendingPathComponent("\(slug)_mic_16k.wav"),
                    micDelay: micDelay,
                )
            }
        }

        /// A file and the span of it that holds a speaker's sample.
        struct SampleSource: Equatable, Sendable {
            let url: URL
            let start: TimeInterval
            let end: TimeInterval
        }

        /// The files and spans to try for `segment`'s sample, best first: the
        /// speaker's own track for an `R_` (app) or `M_` (microphone) label
        /// when the tracks are known, then the mix. The mix carries both sides
        /// at once, and mixing also lowers the microphone while the app track
        /// is loud (`AudioMixer.suppressEcho`), so a local speaker's sample
        /// from it was quiet and choppy and had the far end over it. An
        /// unprefixed label (single-source, or a dual-source job whose one
        /// track failed) has no track to choose. The mix stays in the list so
        /// that a track file that is missing, unreadable or shorter than the
        /// span still plays what it played before.
        func sampleSources(for segment: Segment) -> [SampleSource] {
            var sources: [SampleSource] = []
            if let tracks {
                switch SpeakerKey(encoded: segment.speaker).track {
                case .app:
                    sources.append(SampleSource(url: tracks.app, start: segment.start, end: segment.end))

                case .mic:
                    sources.append(SampleSource(
                        url: tracks.mic, start: segment.start - tracks.micDelay, end: segment.end - tracks.micDelay,
                    ))

                case .single:
                    break
                }
            }
            if let audioPath {
                sources.append(SampleSource(url: audioPath, start: segment.start, end: segment.end))
            }
            return sources
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
