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
    // swiftlint:disable discouraged_optional_boolean
    /// Whether the parked run's task had been cancelled by the time it was
    /// released; nil until a parked run resumes.
    private(set) var sawCancellation: Bool?
    // swiftlint:enable discouraged_optional_boolean

    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private let parksEveryRun: Bool
    private var parksNextRun = false

    /// `parksEveryRun: false` transcribes straight through until
    /// `parkNextRun()` arms a single park, for a test that needs earlier runs
    /// to finish before the one it holds.
    init(parksEveryRun: Bool = true) {
        self.parksEveryRun = parksEveryRun
    }

    func loadModel() {}

    /// Arms a fresh park, also after an earlier one was released: the next
    /// run parks again and `isParked` / `sawCancellation` describe that run.
    func parkNextRun() {
        parksNextRun = true
        isParked = false
        isReleased = false
        sawCancellation = nil
    }

    func transcribeSegments(audioPath _: URL) async -> [TimestampedSegment] {
        guard parksEveryRun || parksNextRun else { return segmentsToReturn }
        parksNextRun = false
        isParked = true
        // Parking only when the release has not already happened keeps the two
        // orderings equivalent. Otherwise a run that arrives here after the
        // caller gave up waiting would park with nobody left to release it, and
        // the suite would hang rather than fail.
        if !isReleased {
            await withCheckedContinuation { parkedContinuation = $0 }
        }
        sawCancellation = Task.isCancelled
        return segmentsToReturn
    }

    /// Let the parked run continue, whether or not it has parked yet.
    func release() {
        isReleased = true
        parkedContinuation?.resume()
        parkedContinuation = nil
    }
}
