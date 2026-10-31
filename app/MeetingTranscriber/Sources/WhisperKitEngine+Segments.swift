import Foundation
import WhisperKit

/// Turning WhisperKit's output into transcript segments. Pure, so the failure
/// rules and the hallucination filter can be tested without a model.
extension WhisperKitEngine {
    /// Segments for one file's decode result. WhisperKit catches whatever its
    /// decode throws into the `Result`, so returning `[]` here would report a
    /// model or audio-load error as "Empty transcript". A cancellation stays a
    /// `CancellationError`; a missing result counts as a failure.
    static func segments(from result: Result<[TranscriptionResult], any Error>?) throws -> [TimestampedSegment] {
        guard let result else {
            throw TranscriptionError.transcriptionFailed(
                underlying: WhisperError.transcriptionFailed("the decoder returned no result"),
            )
        }
        do {
            return try filteredSegments(result.get())
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw TranscriptionError.transcriptionFailed(underlying: error)
        }
    }

    /// Strip Whisper tokens and drop empty text and consecutive repeats (a
    /// common hallucination). Shared by the file and the live-caption path.
    static func filteredSegments(_ results: [TranscriptionResult]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var lastText = ""
        for segment in results.flatMap(\.segments) {
            let text = stripWhisperTokens(segment.text).trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == lastText { continue }
            lastText = text
            segments.append(TimestampedSegment(
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: text,
            ))
        }
        return segments
    }
}
