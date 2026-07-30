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

    /// Reaching the same directory through a symlink must not read as a
    /// different one. When the destination is a link to the staging dir, a
    /// lexical comparison says "not at destination" and the file gets renamed in
    /// place under a fresh stamp, which is how the compounding-rename chain
    /// started. The literal paths in the tests above never exist, so only this
    /// case exercises the resolution.
    func testResolvesSymlinkedDirectories() throws {
        let root = try makeTempDirectory(prefix: "persistence-symlink")
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let source = link.appendingPathComponent("take_mix.wav")
        try Data().write(to: source)

        XCTAssertEqual(
            AudioPersistencePolicy.action(source: source, stagingDir: staging, destinationDir: real),
            .alreadyAtDestination,
            "a symlinked path to the destination must not look like a different directory",
        )
        XCTAssertEqual(
            AudioPersistencePolicy.action(source: source, stagingDir: real, destinationDir: destination),
            .move,
            "a symlinked path into staging is still staging",
        )
    }
}
