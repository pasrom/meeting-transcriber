import Foundation

/// Where a job's recording is transcribed. Captured on the job when it is
/// queued and persisted with it, so a later settings change does not move a
/// job that is already queued or running. A job without one, such as one
/// restored from a snapshot written before this existed, is `.local`.
enum TranscriptionTarget: String, Codable, Sendable {
    case local
    /// An OpenAI-compatible endpoint (`CloudTranscriptionEngine`).
    case cloud
}

/// Picks the engine that transcribes a job with the given target.
typealias TranscriptionEngineResolver = @MainActor (TranscriptionTarget) -> any TranscribingEngine
