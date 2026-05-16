@testable import MeetingTranscriber
import XCTest

/// Drives `WatchLoop.monitorManualRecording` end-to-end through the
/// `startManualRecording` public entry point with injected `pidAliveCheck`
/// + `TestClock`, so the policy's two stop-arms (pid exit, max-duration
/// exceeded) are exercised in the live async loop without spawning a real
/// subprocess.
@MainActor
final class WatchLoopMonitorTests: XCTestCase {
    /// When the monitored process dies, the next poll's
    /// `ManualRecordingMonitorPolicy.step` returns `.stopPidExited` and
    /// `monitorManualRecording` calls `stopManualRecording`. End state:
    /// `.idle`, no manual-recording info, recorder.stop called.
    func testMonitorStopsWhenPidDies() async throws {
        let clock = TestClock()
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pollInterval: 0.05,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
            pidAliveCheck: { _ in false }, // simulated process already exited
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        try await loop.startManualRecording(pid: 42, appName: "Test", title: "T")

        await waitFor(loop.snapshot.phase == .idle, timeout: .seconds(1))
        XCTAssertEqual(loop.snapshot.phase, .idle)
        XCTAssertNil(loop.snapshot.manualRecordingInfo)
        XCTAssertTrue(recorder.stopCalled, "Recorder.stop must be called when pid dies")
    }

    /// When the process stays alive past `maxDuration` virtual time, the
    /// next poll returns `.stopMaxDurationExceeded` and the same stop
    /// path runs.
    func testMonitorStopsOnMaxDurationExceeded() async throws {
        let clock = TestClock()
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pollInterval: 0.05,
            maxDuration: 0.05,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
            pidAliveCheck: { _ in true }, // process never dies
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        try await loop.startManualRecording(pid: 42, appName: "Test", title: "T")

        await waitFor(loop.snapshot.phase == .idle, timeout: .seconds(1))
        XCTAssertEqual(loop.snapshot.phase, .idle)
        XCTAssertNil(loop.snapshot.manualRecordingInfo)
        XCTAssertTrue(recorder.stopCalled, "Recorder.stop must be called when maxDuration hits")
    }
}
