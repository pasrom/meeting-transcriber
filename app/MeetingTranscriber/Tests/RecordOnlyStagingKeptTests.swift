@testable import MeetingTranscriber
import XCTest

/// A record-only write that committed but could not remove its staging files
/// tells the user, on both the normal and the quit path: the next launch's
/// orphan scan finds the mix still in staging and processes the recording
/// again, next to its record-only output.
@MainActor
final class RecordOnlyStagingKeptTests: XCTestCase {
    private func makeLoop(notifier: RecordingNotifier) async throws -> WatchLoop {
        let staging = try makeTempDirectory(prefix: "record_only_kept_staging")
        let output = try makeTempDirectory(prefix: "record_only_kept_output")
        let mix = staging.appendingPathComponent("20260311_140000_mix.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000, url: mix)
        // Read-only, so the committed write cannot remove its source.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staging.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        }
        let recorder = MockRecorder()
        recorder.mixPath = mix
        let loop = WatchLoop(
            detector: FixedMeetingDetector(),
            recorderFactory: { recorder },
            recordOnly: { true },
            recordOnlyDestination: { .unscoped(output) },
            notifier: notifier,
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.startManualRecording(pid: getpid(), appName: "Teams", title: "Standup")
        return loop
    }

    func testAStopWhoseStagingFileStaysTellsTheUser() async throws {
        let notifier = RecordingNotifier()
        let loop = try await makeLoop(notifier: notifier)

        loop.stopManualRecording()

        XCTAssertEqual(notifier.calls.map(\.title), ["Record-only: files left in staging"])
    }

    func testAQuitWhoseStagingFileStaysTellsTheUser() async throws {
        let notifier = RecordingNotifier()
        let loop = try await makeLoop(notifier: notifier)

        await loop.finishForQuit()

        XCTAssertEqual(notifier.calls.map(\.title), ["Record-only: files left in staging"])
    }
}
