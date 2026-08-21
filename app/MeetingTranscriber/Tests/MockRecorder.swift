@testable import MeetingTranscriber
import XCTest

// The `RecordingProvider` doubles, split out of `TestHelpers.swift` when that
// file reached the 600-line cap. `ThrowingRecorder` lives here rather than in a
// file of its own because the two stand in for the recorder at the same seam: a
// test picks between them by which outcome it needs, a stop that completes or a
// start that cannot open.

/// A `MockRecorder` that can complete a stop. Without `mixPath` its `stop()`
/// throws `noAudioData`, which is the *lost recording* path, not the happy one —
/// a test that means to exercise a clean stop and forgets this pins the wrong
/// behaviour as correct.
@MainActor
func makeMockRecorder() -> MockRecorder {
    let recorder = MockRecorder()
    recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
    return recorder
}

/// Mock recorder that returns a pre-prepared fixture WAV as the recording result.
@MainActor
class MockRecorder: RecordingProvider {
    var mixPath: URL?
    var appPath: URL?
    var micPath: URL?
    var startCalled = false
    var stopCalled = false

    /// Args captured from the last `start(...)` so tests can pin that `WatchLoop`
    /// threads them through (appPID, noMic, micDeviceUID) instead of only checking
    /// `startCalled`. Defaults are deliberately "impossible" values so an unset or
    /// dropped argument fails an equality assertion rather than passing silently.
    var capturedSource: RecordingSource?
    var capturedMicDeviceUID: String?

    /// Per-channel level overrides for asymmetric-silence tests. Both default to -120
    /// (silence) so existing tests that don't touch these see the same behavior as
    /// the protocol's default implementations.
    var micLevelDBFS: Double = -120
    var appLevelDBFS: Double = -120
    /// Whether a channel's capture restart was abandoned (issue #588). Default
    /// false, matching the protocol's default, so existing tests are unaffected.
    var micCaptureGaveUp = false
    var appCaptureGaveUp = false

    /// Overrides the `recordingStartDate` `stop()` reports. `nil` (default)
    /// yields `Date()` at stop time, matching a real recorder; set it to pin a
    /// specific meeting-start time (e.g. filename-anchoring tests).
    var recordingStartDate: Date?

    func start(source: RecordingSource, micDeviceUID: String?, debugLogging _: Bool) {
        startCalled = true
        capturedSource = source
        capturedMicDeviceUID = micDeviceUID
    }

    func stop() throws -> RecordingResult {
        stopCalled = true
        guard let mix = mixPath else {
            throw RecorderError.noAudioData
        }
        return RecordingResult(
            mixPath: mix,
            appPath: appPath,
            micPath: micPath,
            micDelay: 0,
            recordingStartDate: recordingStartDate ?? Date(),
        )
    }
}

/// A recorder whose `start` fails the way a busy or absent input device does.
/// Injected through the `makeRecorder:` seam so the non-permission failure arm
/// is reachable without hardware. Shared so the files that need it don't reach
/// across into each other.
@MainActor
final class ThrowingRecorder: RecordingProvider {
    func start(source _: RecordingSource, micDeviceUID _: String?, debugLogging _: Bool) throws {
        throw RecorderError.noAudioData
    }

    func stop() throws -> RecordingResult {
        throw RecorderError.notRecording
    }
}
