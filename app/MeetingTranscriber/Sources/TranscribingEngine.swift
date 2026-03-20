import Foundation
import WhisperKit

/// Common interface for transcription engine implementations (WhisperKit, Parakeet, …).
@MainActor
protocol TranscribingEngine: AnyObject {
    var modelState: ModelState { get }
    var downloadProgress: Double { get }
    var transcriptionProgress: Double { get } // swiftlint:disable:this unused_declaration

    func loadModel() async
    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment]
}

extension TranscribingEngine {
    /// Label and merge pre-transcribed app/mic segments by timestamp.
    func mergeDualSourceSegments(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        micDelay: TimeInterval = 0,
        micLabel: String = "Me",
    ) -> [TimestampedSegment] {
        var app = appSegments
        var mic = micSegments

        if micDelay != 0 {
            mic = mic.map { seg in
                TimestampedSegment(
                    start: seg.start + micDelay,
                    end: seg.end + micDelay,
                    text: seg.text,
                    speaker: seg.speaker,
                )
            }
        }

        for i in app.indices {
            app[i].speaker = "Remote"
        }
        for i in mic.indices {
            mic[i].speaker = micLabel
        }

        var result = app + mic
        result.sort { $0.start < $1.start }
        return result
    }
}
