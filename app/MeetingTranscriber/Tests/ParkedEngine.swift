import Foundation
@testable import MeetingTranscriber

/// Transcription engine that parks inside `transcribeSegments` until the test
/// releases it. Lets a test hold one pipeline run mid-stage, past the point
/// where it has written its intermediate 16 kHz files, while a second run of
/// the same job is driven to completion. That is the only way to observe how
/// two concurrent runs treat each other's working files.
///
/// Callers wait for `isParked` via `waitFor` rather than a second continuation,
/// so a run that regresses and never reaches transcription fails the test on
/// the timeout instead of hanging the suite.
///
/// Kept out of `TestHelpers.swift` so that file stays under its length limit.
@MainActor
final class ParkedEngine: TranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1.0
    var transcriptionProgress: Double = 1.0
    var providesTimestamps = true
    var segmentsToReturn: [TimestampedSegment] = []

    /// True once a run has entered `transcribeSegments` and suspended there.
    private(set) var isParked = false

    private var parkedContinuation: CheckedContinuation<Void, Never>?

    func loadModel() {}

    func transcribeSegments(audioPath _: URL) async -> [TimestampedSegment] {
        isParked = true
        await withCheckedContinuation { parkedContinuation = $0 }
        return segmentsToReturn
    }

    /// Let the parked run continue.
    func release() {
        parkedContinuation?.resume()
        parkedContinuation = nil
    }
}
