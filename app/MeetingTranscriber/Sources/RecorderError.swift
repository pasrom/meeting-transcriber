import Foundation

/// Why a recording could not start or produced nothing to process. Its own
/// file rather than the tail of `DualSourceRecorder.swift`, which is at the
/// line cap; `WatchLoop` and `WatchingController` throw and match it too.
enum RecorderError: LocalizedError {
    case notRecording
    case noAudioData
    case unsupportedOS
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .notRecording: "Not currently recording"
        case .noAudioData: "No audio data recorded"
        case .unsupportedOS: "macOS 14.2+ required for audio capture"
        case let .permissionDenied(reason): "Permission problem: \(reason)"
        }
    }
}
