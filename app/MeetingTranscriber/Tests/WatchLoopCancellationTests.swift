@testable import MeetingTranscriber
import XCTest

/// Regression coverage for the Stop-Watching-mid-recording data-loss bug
/// (issue #84, amit-math): cancelling the watch task while `handleMeeting` is
/// recording an auto-detected meeting must finalize the recording
/// (`recorder.stop()` + `enqueueRecording()`) instead of discarding it. Both
/// `AppState.toggleWatching` and `startManualRecording` call `loop.stop()` →
/// `watchTask.cancel()` while a meeting may be in flight; previously
/// `waitForMeetingEnd` threw `CancellationError`, so the finalization lines
/// never ran — total loss, no naming dialog, orphaned `_app_raw.tmp` reaped on
/// next launch.
@MainActor
final class WatchLoopCancellationTests: XCTestCase {
    /// Drives `handleMeeting` directly and cancels mid-recording. Pins the
    /// finalize-on-cancel logic: the cancelled task must still stop the
    /// recorder and enqueue a job.
    func testCancellationMidRecordingFinalizesAndEnqueues() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix_cancel.wav")
        let queue = PipelineQueue(logDir: tmpDir)

        // Fires once handleMeeting has reached its first `waitForMeetingEnd`
        // sleep — i.e. recording is live and the loop is parked. Cancelling
        // before this point would exercise a different (pre-record) path.
        let reachedWait = expectation(description: "handleMeeting parked in waitForMeetingEnd")
        nonisolated(unsafe) var signalled = false

        // Bound to a named local (not a trailing closure) so SwiftFormat
        // doesn't rewrite the labeled `sleepProvider:` argument into a
        // trailing closure — which would bind to the init's last parameter
        // (`pidAliveCheck`) instead and fail to compile.
        let sleepProvider: (TimeInterval) async throws -> Void = { interval in
            if !signalled {
                signalled = true
                reachedWait.fulfill()
            }
            try await Task.sleep(for: .seconds(interval))
        }
        let loop = WatchLoop(
            detector: AlwaysActiveDetector(),
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            endGracePeriod: 100, // never ends naturally during the test window
            maxDuration: 100,
            noMic: true,
            sleepProvider: sleepProvider,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        let meeting = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Standup | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 4242,
        )

        let task = Task { try await loop.handleMeeting(meeting) }
        await fulfillment(of: [reachedWait], timeout: 2)
        task.cancel()
        _ = try? await task.value

        XCTAssertTrue(recorder.startCalled, "recorder.start must have been called")
        XCTAssertTrue(
            recorder.stopCalled,
            "in-flight recording must be finalized on cancel, not discarded",
        )
        XCTAssertEqual(
            queue.jobs.count, 1,
            "finalized recording must be enqueued so the speaker-naming dialog can fire",
        )
    }

    /// Companion to the test above, but exercised through the *production*
    /// `start()` → watchTask → `watchLoop()` → `handleMeeting()` chain and a
    /// real `stop()` (the exact path `AppState.toggleWatching` drives), not by
    /// calling `handleMeeting` directly. This pins the load-bearing detail the
    /// direct-call test can't: `start()`'s `Task { [weak self] … }` must keep
    /// the loop alive through finalization after `stop()` nils `watchTask`. A
    /// regression in that retention would pass the direct-call test yet lose
    /// recordings in production.
    func testStopThroughStartStopChainFinalizesInFlightRecording() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-chain-\(UUID())")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix_chain.wav")
        let queue = PipelineQueue(logDir: tmpDir)

        let meeting = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Standup | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 4242,
        )

        // Fulfilled once the watchTask has driven handleMeeting into its first
        // waitForMeetingEnd sleep — recording is live, loop is parked.
        let reachedWait = expectation(description: "watchTask parked in waitForMeetingEnd")
        nonisolated(unsafe) var signalled = false
        let sleepProvider: (TimeInterval) async throws -> Void = { interval in
            if !signalled {
                signalled = true
                reachedWait.fulfill()
            }
            try await Task.sleep(for: .seconds(interval))
        }
        let loop = WatchLoop(
            detector: RecordingMeetingDetector(meeting: meeting),
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            endGracePeriod: 100,
            maxDuration: 100,
            noMic: true,
            sleepProvider: sleepProvider,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        loop.start()
        await fulfillment(of: [reachedWait], timeout: 2)

        loop.stop() // production Stop Watching → watchTask.cancel()

        // The cancelled watchTask resumes and finalizes synchronously; yield
        // until the job lands (bounded so a regression fails instead of hangs).
        let deadline = Date().addingTimeInterval(2)
        while queue.jobs.isEmpty, Date() < deadline {
            await Task.yield()
        }

        XCTAssertTrue(
            recorder.stopCalled,
            "Stop Watching through the real start/stop chain must finalize the recording",
        )
        XCTAssertEqual(queue.jobs.count, 1, "finalized recording must be enqueued")
        XCTAssertEqual(loop.state, .idle, "loop returns to idle after stop")
    }
}

/// Reports a meeting as permanently active, so `waitForMeetingEnd` never
/// resolves on its own — the only way out is task cancellation. `checkOnce`
/// returns nil so it's only usable for tests that call `handleMeeting`
/// directly.
private final class AlwaysActiveDetector: MeetingDetecting {
    func checkOnce() -> DetectedMeeting? {
        nil
    }

    func isMeetingActive(_: DetectedMeeting) -> Bool {
        true
    }

    func reset(appName _: String?) {}
}

/// Like `AlwaysActiveDetector` but also surfaces the meeting from `checkOnce()`,
/// so the production `start()` → `watchLoop()` poll picks it up and enters
/// `handleMeeting`. Immutable `meeting` keeps the detector Sendable-safe.
private final class RecordingMeetingDetector: MeetingDetecting {
    let meeting: DetectedMeeting

    init(meeting: DetectedMeeting) {
        self.meeting = meeting
    }

    func checkOnce() -> DetectedMeeting? {
        meeting
    }

    func isMeetingActive(_: DetectedMeeting) -> Bool {
        true
    }

    func reset(appName _: String?) {}
}
