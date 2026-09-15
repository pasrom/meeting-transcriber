import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// What `buildRecording` does when one of its inputs is unusable.
///
/// Split out of `DualSourceRecorderTests`, which was at the 400-line type-body
/// ceiling. These two are a pair: one says a failure that can be worked around
/// is worked around, the other says a failure that cannot be leaves the crash-
/// recovery source intact.
final class BuildRecordingFailureModeTests: XCTestCase {
    func testAnUndecodableMicFileDegradesToAppOnlyInsteadOfFailing() throws {
        // This used to assert a throw. It cannot any more, and that is the
        // point: the mic load moved above the app WAV write, so a throw here
        // would leave no `_app.wav` at all, and the next launch runs recovery
        // (which retries the same unreadable file and throws again) and then
        // `cleanupTempFiles`, which deletes the raw temp once it is older than
        // thirty seconds. The app audio would be gone. Degrading to app-only
        // gives the user that audio now instead of never.
        let dir = try makeTempDirectory(prefix: "build_bad_mic")
        let appTmp = dir.appendingPathComponent("20260311_160000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)
        // Larger than a WAV header and not decodable audio, so it clears the
        // size guard and then fails to open.
        let badMic = dir.appendingPathComponent("20260311_160000_mic.wav")
        try Data(repeating: 0xFF, count: 128).write(to: badMic)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: badMic,
                actualSampleRate: 48000, actualChannels: 2, micDelay: 0,
            ),
            recordingsDir: dir, timestamp: "20260311_160000", recordingStartDate: Date(timeIntervalSince1970: 1000),
            format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
        )

        XCTAssertNotNil(result.appPath, "the app track is what there was to rescue")
        XCTAssertNil(result.micPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mixPath.path))
    }

    func testBuildRecordingPreservesAppTempWhenLaterStepThrows() throws {
        // The temp is the crash-recovery source, so any failure before a durable
        // mix exists has to leave it alone. The failure used here is an output
        // directory that is not a directory, which throws inside the app WAV
        // write, after the temp has been read.
        let dir = try makeTempDirectory(prefix: "build_preserve")
        let appTmp = dir.appendingPathComponent("20260311_160000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)
        let notADirectory = dir.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: notADirectory)

        XCTAssertThrowsError(
            try DualSourceRecorder.buildRecording(
                from: AudioCaptureResult(
                    appAudioFileURL: appTmp, micAudioFileURL: nil,
                    actualSampleRate: 48000, actualChannels: 2, micDelay: 0,
                ),
                recordingsDir: notADirectory, timestamp: "20260311_160000",
                recordingStartDate: Date(timeIntervalSince1970: 1000),
                format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
            ),
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appTmp.path),
            "app .tmp must survive a failed buildRecording so crash-recovery can retry",
        )
    }
}
