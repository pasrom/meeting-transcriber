@testable import AudioTapLib
import XCTest

/// `SilentTrackDiagnostics` owns the queue the process-state reads run on, the
/// guard that keeps a wedged read from piling up, and the observer's state
/// (issue #672). The reads themselves need hardware; everything around them is
/// what this pins.
final class SilentTrackDiagnosticsTests: XCTestCase {
    private let processes = [TappedProcess(pid: 1, audioObjectID: 11)]

    /// Records probe calls and lets a test hold one open, which is how the
    /// wedged-read case is reproduced without a wedged HAL.
    private final class ProbeSpy: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func probe(hold: Bool) -> SilentTrackDiagnostics.Probe {
            { [self] _ in
                lock.lock(); _calls += 1; lock.unlock()
                entered.signal()
                if hold { release.wait() }
                return []
            }
        }
    }

    // MARK: - The guard

    func testASecondProbeIsRefusedWhileTheFirstIsStillRunning() {
        let spy = ProbeSpy()
        let diagnostics = SilentTrackDiagnostics(probe: spy.probe(hold: true)) { _, _ in }

        XCTAssertTrue(diagnostics.probeAsync(processes, reason: "first"))
        XCTAssertEqual(spy.entered.wait(timeout: .now() + 2), .success, "the first probe started")

        // A HAL read that never comes back must cost one parked thread, not a
        // growing queue of them. This is the whole reason the guard exists.
        XCTAssertFalse(diagnostics.probeAsync(processes, reason: "second"))
        XCTAssertFalse(diagnostics.probeAsync(processes, reason: "third"))

        spy.release.signal()
        XCTAssertEqual(spy.calls, 1)
    }

    func testAProbeCanRunAgainOnceTheFirstReturned() {
        let spy = ProbeSpy()
        let done = expectation(description: "both probes reported")
        done.expectedFulfillmentCount = 2
        let diagnostics = SilentTrackDiagnostics(probe: spy.probe(hold: false)) { _, _ in
            done.fulfill()
        }

        XCTAssertTrue(diagnostics.probeAsync(processes, reason: "first"))
        XCTAssertEqual(spy.entered.wait(timeout: .now() + 2), .success)
        // Wait for the in-flight flag to clear, which happens after the sink.
        var restarted = false
        for _ in 0 ..< 100 where !restarted {
            restarted = diagnostics.probeAsync(processes, reason: "second")
            if !restarted { usleep(20000) }
        }
        XCTAssertTrue(restarted, "the guard must clear when the probe returns")
        wait(for: [done], timeout: 5)
    }

    func testTheReasonReachesTheSink() {
        // Asserted inside the sink rather than through a box: the sink is
        // `@Sendable`, so anything it writes back out would need its own lock
        // for one string.
        let reported = expectation(description: "reported")
        let diagnostics = SilentTrackDiagnostics(probe: { _ in [] }, sink: { reason, _ in
            XCTAssertEqual(reason, "stop")
            reported.fulfill()
        })
        diagnostics.probeAsync(processes, reason: "stop")
        wait(for: [reported], timeout: 5)
    }

    func testARefusedProbeIsReportedRatherThanSwallowed() {
        // A skip means an earlier read has not come back. If that one is wedged,
        // every later probe is skipped for the rest of the recording, and a
        // silent skip would leave a log that is simply missing, with nothing
        // saying why.
        let spy = ProbeSpy()
        let skipped = expectation(description: "skip reported")
        let diagnostics = SilentTrackDiagnostics(probe: spy.probe(hold: true)) { reason, outcome in
            guard outcome == .skipped else { return }
            XCTAssertEqual(reason, "second")
            skipped.fulfill()
        }
        XCTAssertTrue(diagnostics.probeAsync(processes, reason: "first"))
        XCTAssertEqual(spy.entered.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(diagnostics.probeAsync(processes, reason: "second"))
        wait(for: [skipped], timeout: 5)
        spy.release.signal()
    }

    func testAProbeStillReportsAfterItsOwnerIsReleased() {
        // The stop reading is requested from AppAudioCapture.stop(), and
        // AudioCaptureSession releases the capture object a few statements
        // later, which releases this one with it. Under a weak capture the
        // queue found nothing left and the stop reading was lost almost every
        // time, which is the one reading the whole feature exists to produce.
        //
        // The release below wins the race against the queue by a wide margin
        // (an async dispatch costs microseconds, the next statement does not),
        // so under the defect this times out rather than flaking green.
        let reported = expectation(description: "reported after release")
        var diagnostics: SilentTrackDiagnostics? = SilentTrackDiagnostics(
            probe: { _ in [] }, sink: { _, _ in reported.fulfill() },
        )
        diagnostics?.probeAsync(processes, reason: "stop")
        diagnostics = nil
        wait(for: [reported], timeout: 5)
    }

    // MARK: - What the stop summary reads

    func testTheRememberedProcessesSurviveASessionThatIsAlreadyGone() {
        // .stopAndRetry clears the tap session before any restart attempt
        // launches, and only adoption puts one back. So on every give-up and
        // mid-restart stop the session is nil, which is exactly the recording
        // whose process state is worth having.
        let diagnostics = SilentTrackDiagnostics(probe: { _ in [] }, sink: { _, _ in })
        XCTAssertTrue(diagnostics.lastInstalledProcesses.isEmpty)
        diagnostics.remember(processes)
        XCTAssertEqual(diagnostics.lastInstalledProcesses, processes)
    }

    func testAnEmptyProcessListStillReports() {
        // A session built by a test seam has no tapped processes. The stop line
        // must still be written, saying so, rather than vanishing.
        let reported = expectation(description: "reported")
        let diagnostics = SilentTrackDiagnostics(probe: ProcessOutputProbe.readAll) { _, outcome in
            XCTAssertEqual(outcome, .read([]))
            reported.fulfill()
        }
        XCTAssertTrue(diagnostics.probeAsync([], reason: "start"))
        wait(for: [reported], timeout: 5)
    }

    // MARK: - The observer behind it

    func testTheEdgeIsHandedBackToTheCaller() {
        let diagnostics = SilentTrackDiagnostics(probe: { _ in [] }, sink: { _, _ in })
        XCTAssertNil(diagnostics.observe(ages(energy: 0.5)))
        XCTAssertEqual(
            diagnostics.observe(ages(energy: 11.0)),
            .enteredZeroRun(afterSignalSeconds: 11.0),
        )
    }

    func testTheCountersSurviveForTheStopSummary() {
        let diagnostics = SilentTrackDiagnostics(probe: { _ in [] }, sink: { _, _ in })
        _ = diagnostics.observe(ages(energy: 30.0))
        _ = diagnostics.observe(ages(energy: 0.02))
        _ = diagnostics.observe(ages(energy: 12.0))
        let counters = diagnostics.counters
        XCTAssertEqual(counters.zeroRuns, 2)
        XCTAssertEqual(counters.longestZeroRun, 30.0)
    }
}
