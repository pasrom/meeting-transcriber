@testable import MeetingTranscriber
import XCTest

/// Indirect coverage for the `WatchLoop.update(_:)` mutation funnel.
/// Mostly exercised through the entry points (`start`, `stop`, manual
/// recording), inspecting the resulting `snapshot` + `onStateChange`
/// callback log; the detail-only case calls the funnel directly.
@MainActor
final class WatchLoopUpdateFunnelTests: XCTestCase {
    /// A single funnel call carries co-located mutations atomically:
    /// `start` flips phase to `.watching` AND sets a fresh `detail` in one
    /// snapshot transition. Multi-step writes that previously could be
    /// observed mid-flight (phase changed, detail not yet) are now coherent.
    func testStartEmitsCoherentSnapshotTransition() {
        let (loop, _) = makeTestWatchLoop()
        var observed: [WatchLoopState] = []
        loop.onStateChange = { [weak loop] _, _, _ in
            if let loop { observed.append(loop.snapshot) }
        }

        loop.start()
        defer { loop.stop() }

        XCTAssertEqual(observed.count, 1, "Exactly one phase transition fires for start()")
        XCTAssertEqual(observed.first?.phase, .watching)
        XCTAssertEqual(observed.first?.detail, "Polling for meetings...")
    }

    /// `onStateChange` is invoked only when the *phase* changes. A funnel
    /// call that touches another field (e.g. `lastError`) with the phase
    /// unchanged must not fire the callback.
    func testDetailOnlyUpdateDoesNotFireOnStateChange() {
        let (loop, _) = makeTestWatchLoop()
        loop.start()
        defer { loop.stop() }
        var phaseTransitions = 0
        loop.onStateChange = { _, _, _ in phaseTransitions += 1 }

        loop.update { $0.detail = "Still polling" }

        XCTAssertEqual(loop.snapshot.detail, "Still polling", "the funnel must commit the detail")
        XCTAssertEqual(phaseTransitions, 0, "a detail-only update must not report a phase change")
    }

    /// The phase-transition callback receives the old phase observed
    /// *before* the funnel commits the new snapshot — even when the
    /// funnel mutates other fields in the same transform.
    func testOnStateChangeReportsOldPhaseBeforeCommit() {
        let (loop, _) = makeTestWatchLoop()
        loop.start()
        var lastPair: (WatchLoop.State, WatchLoop.State)?
        loop.onStateChange = { old, new, _ in lastPair = (old, new) }

        loop.stop()

        XCTAssertEqual(lastPair?.0, .watching)
        XCTAssertEqual(lastPair?.1, .idle)
    }

    /// Manual recording sets phase + manualRecordingInfo + detail in a
    /// single funnel call. Snapshot read after start sees all three.
    func testManualRecordingStartAtomicallyUpdatesAllFields() async throws {
        let (loop, _) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 99, appName: "Zoom", title: "Daily")
        defer { loop.stop() }

        let snap = loop.snapshot
        XCTAssertEqual(snap.phase, .recording)
        XCTAssertEqual(snap.detail, "Recording: Daily")
        XCTAssertEqual(
            snap.manualRecordingInfo,
            ManualRecordingInfo(pid: 99, appName: "Zoom", title: "Daily"),
        )
    }

    /// When `recorder.stop()` throws, the funnel still transitions to
    /// `.idle` and surfaces the error message via `lastError` — both in
    /// a single coherent snapshot, not a split mid-flight observation.
    func testStopManualRecordingSurfacesRecorderErrorThroughFunnel() async throws {
        let (loop, recorder) = makeTestWatchLoop()
        recorder.mixPath = nil // forces MockRecorder.stop() to throw .noAudioData

        try await loop.startManualRecording(pid: 7, appName: "Webex", title: "Sync")
        XCTAssertEqual(loop.snapshot.phase, .recording)

        loop.stopManualRecording()

        let snap = loop.snapshot
        XCTAssertEqual(snap.phase, .idle, "Phase still transitions to idle on stop failure")
        XCTAssertNil(snap.manualRecordingInfo, "Manual info cleared even when stop throws")
        XCTAssertEqual(snap.detail, "")
        XCTAssertNotNil(snap.lastError, "Recorder error must surface via funnel's lastError")
    }
}
