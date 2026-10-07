@testable import MeetingTranscriber
import XCTest

/// Two staging recoveries can run at once: every queue rebuild starts one, and
/// at launch the first build and an auto-watch start follow each other within
/// milliseconds. Both scan the folder before either has written a mix, so both
/// pick the same crashed stem.
@MainActor
final class DualSourceRecorderRecoveryOverlapTests: XCTestCase {
    /// The second recovery comes to the stem after the first has finished it:
    /// the mix is in place and `buildRecording` has removed the raw app temp.
    /// What is left (the microphone track alone) is exactly the shape a
    /// microphone-only recording has, so recovering it again built a
    /// microphone-only mix and renamed it over the complete one: a valid file
    /// that has silently lost the far end.
    func testASecondRecoveryOfAStemTheFirstAlreadyMixedLeavesTheMixAlone() throws {
        let dir = try makeTempDirectory(prefix: "recovery_overlap")
        let stem = "20260311_140000"
        let appTmp = dir.appendingPathComponent(stem + RecordingFileSuffix.appRaw)
        try writeRawFloat32([Float](repeating: 0.3, count: 16000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        try Data().write(to: DualSourceRecorder.inProgressMarker(stem: stem, in: dir))
        try backdate([appTmp, micWav])

        // The first recovery, start to finish.
        XCTAssertEqual(DualSourceRecorder.recoverCrashedRecordings(in: dir), 1)
        let mix = dir.appendingPathComponent(stem + RecordingFileSuffix.mix)
        let complete = try AudioMixer.loadAudioFileAsFloat32(url: mix).count
        XCTAssertEqual(complete, 16000 * 2, "test premise: the first recovery mixed both tracks")

        // The second, acting on the selection it made before the first had
        // written anything.
        _ = try? DualSourceRecorder.recoverCrashedRecording(stem: stem, in: dir)

        XCTAssertEqual(
            try AudioMixer.loadAudioFileAsFloat32(url: mix).count, complete,
            "a second recovery replaced the complete mix with a microphone-only one",
        )
    }
}
