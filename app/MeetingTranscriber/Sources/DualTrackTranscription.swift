import Foundation

/// What a dual-source job keeps from its two transcription passes.
///
/// `DualTrackViability` keeps an empty track from taking the intact one down
/// with it, but it decides from frame counts, before any decode. A track can
/// pass that check and still fail on its own file (audio the decoder cannot
/// read, a decode that breaks on it). Such a track is dropped the same way, and
/// the verdict is downgraded with it, so every stage that already reads the
/// verdict (the transcript note, echo dedup, both diarization runs) treats it
/// as a track that is not there.
///
/// Only a failure scoped to the file of a `.both` pair reaches this type
/// (`TranscriptionFailureScope`); the caller throws everything else, an
/// engine-wide failure before the second track is tried.
enum DualTrackTranscription {
    typealias Attempt = Result<[TimestampedSegment], any Error>

    struct Kept {
        let app: [TimestampedSegment]
        let mic: [TimestampedSegment]
        /// The verdict after the passes: `.appOnly`/`.micOnly` for a pair
        /// that lost one track to a failure, otherwise the one passed in.
        let viability: DualTrackViability
        /// One per dropped track, for the job's warnings.
        let warnings: [String]
    }

    /// - Parameters:
    ///   - app: `nil` for a track that was not handed to the engine.
    ///   - mic: Same, for the microphone.
    ///   - viability: The verdict taken from the frame counts.
    /// - Throws: The first failure (app before microphone) when no surviving
    ///   track produced a segment: with nothing transcribed, the failure is
    ///   the explanation, and reporting "Empty transcript" instead would hide
    ///   it.
    static func resolve(app: Attempt?, mic: Attempt?, viability: DualTrackViability) throws -> Kept {
        let failures = [app, mic].compactMap { attempt -> (any Error)? in
            if case let .failure(error)? = attempt { error } else { nil }
        }
        let appSegments = segments(of: app)
        let micSegments = segments(of: mic)
        if let first = failures.first, appSegments.isEmpty, micSegments.isEmpty {
            throw first
        }

        var kept = viability
        var warnings: [String] = []
        if case let .failure(error) = app {
            kept = .micOnly
            warnings.append(
                "The app-audio track could not be transcribed (\(error.localizedDescription)) — transcribed the microphone only",
            )
        }
        if case let .failure(error) = mic {
            kept = .appOnly
            warnings.append(
                "The microphone track could not be transcribed (\(error.localizedDescription)) — transcribed the app audio only",
            )
        }
        return Kept(app: appSegments, mic: micSegments, viability: kept, warnings: warnings)
    }

    private static func segments(of attempt: Attempt?) -> [TimestampedSegment] {
        if case let .success(segments) = attempt { segments } else { [] }
    }
}
