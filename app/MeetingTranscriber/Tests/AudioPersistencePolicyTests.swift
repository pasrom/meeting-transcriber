@testable import MeetingTranscriber
import XCTest

final class AudioPersistencePolicyTests: XCTestCase {
    private let staging = URL(fileURLWithPath: "/data/MeetingTranscriber/recordings")
    private let destination = URL(fileURLWithPath: "/Users/x/Documents/Protocols/recordings")

    private func action(_ path: String) -> AudioPersistenceAction {
        AudioPersistencePolicy.action(
            source: URL(fileURLWithPath: path), stagingDir: staging, destinationDir: destination,
        )
    }

    /// A recording the app made itself: staging is a working area, so moving it
    /// into the output folder is the normal hand-off.
    func testStagingRecordingMoves() {
        XCTAssertEqual(action("/data/MeetingTranscriber/recordings/20260101_sync_mix.wav"), .move)
    }

    /// The case issue #551 is about: a voice memo the user picked from their own
    /// folder must not be relocated.
    func testUserPickedFileStaysInPlace() {
        XCTAssertEqual(action("/Users/x/Downloads/voice-memo.opus"), .leaveInPlace)
        XCTAssertEqual(action("/Users/x/Library/Mobile Documents/call.3gp"), .leaveInPlace)
    }

    /// Re-importing something that already lives in the output folder must not
    /// rename it under a fresh timestamp, which would make orphan recovery pick
    /// the new name again on the next launch.
    func testFileAlreadyInDestinationIsLeftAlone() {
        XCTAssertEqual(
            action("/Users/x/Documents/Protocols/recordings/20260101_sync_mix.wav"),
            .alreadyAtDestination,
        )
    }

    /// Nested directories are not the staging dir itself. Only files written
    /// directly into staging are the app's own.
    func testSubdirectoryOfStagingIsNotStaging() {
        XCTAssertEqual(action("/data/MeetingTranscriber/recordings/old/archived_mix.wav"), .leaveInPlace)
    }

    /// Path comparison must survive the non-normalized forms a caller can pass
    /// in, otherwise a staging file would be misread as a user file and the
    /// hand-off into the output folder would silently stop happening.
    func testNormalizesPathsBeforeComparing() {
        XCTAssertEqual(action("/data/MeetingTranscriber/recordings/./take_mix.wav"), .move)
        XCTAssertEqual(action("/data/MeetingTranscriber/other/../recordings/take_mix.wav"), .move)
    }
}
