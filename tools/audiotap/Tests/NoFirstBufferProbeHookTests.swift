@testable import AudioTapLib
import XCTest

/// That the diagnostics hand each no-first-buffer probe's reading, with its
/// offset, to the hook the capture arms the probes with (issue #693), and
/// only while the probe's arming is still the current one. Without this the
/// hook can be dropped from `scheduleNoBufferProbes` and the policy tests stay
/// green. `ProbeClock` is shared with `NoFirstBufferProbeSchedulingTests`.
final class NoFirstBufferProbeHookTests: XCTestCase {
    func testTheProbeHandsItsReadingAndOffsetToTheHook() {
        let clock = ProbeClock()
        let heard = expectation(description: "hook heard the probe")
        let snapshot = SilentTrackDiagnostics.ProbeSnapshot(processes: [], device: nil)
        let diagnostics = SilentTrackDiagnostics(
            probe: { _, _ in snapshot },
            sink: { _, _ in },
            delayedWork: { clock.arm($0, $1) },
        )

        diagnostics.scheduleNoBufferProbes([], aggregateID: 42, schedule: .init(offsets: [5])) { offset, reading in
            XCTAssertEqual(offset, 5)
            XCTAssertEqual(reading, snapshot)
            heard.fulfill()
        }
        clock.fireAll()

        wait(for: [heard], timeout: 5)
    }

    /// The first buffer disarms the probes, but cannot stop one whose read is
    /// already inside coreaudiod. Such a reading is about a tap that
    /// delivers: it is still logged, and it must not reach the watchdog.
    func testAProbeOvertakenByAFirstBufferDuringItsReadIsLoggedButDoesNotReachTheHook() {
        assertProbeOvertaken { $0.cancelNoBufferProbes() }
    }

    /// The same for a newer tap's arming, a teardown and restart that
    /// overlapped the read: the watchdog would otherwise put the tap
    /// installed now on trial for a reading taken about the one before it.
    func testAProbeOvertakenByANewerArmingDuringItsReadDoesNotReachTheHook() {
        assertProbeOvertaken { $0.scheduleNoBufferProbes([], aggregateID: 43) }
    }

    /// Arms one probe whose read performs `overtake` on the diagnostics
    /// before it returns, then asserts that the sink hears the reading and
    /// the hook does not.
    private func assertProbeOvertaken(_ overtake: @escaping @Sendable (SilentTrackDiagnostics) -> Void) {
        let clock = ProbeClock()
        let logged = expectation(description: "the probe still logs its reading")
        let heard = expectation(description: "hook heard the probe")
        heard.isInverted = true
        let snapshot = SilentTrackDiagnostics.ProbeSnapshot(processes: [], device: nil)
        let overtaker = Overtaker()
        let diagnostics = SilentTrackDiagnostics(
            probe: { _, _ in
                if let diagnostics = overtaker.diagnostics { overtake(diagnostics) }
                return snapshot
            },
            sink: { _, outcome in
                if outcome == .read(snapshot) { logged.fulfill() }
            },
            delayedWork: { clock.arm($0, $1) },
        )
        overtaker.diagnostics = diagnostics

        diagnostics.scheduleNoBufferProbes([], aggregateID: 42, schedule: .init(offsets: [5])) { _, _ in
            heard.fulfill()
        }
        clock.fireAll()

        wait(for: [logged, heard], timeout: 1)
    }
}

/// Lets the probe closure reach the diagnostics it is handed to, which do not
/// exist yet when the closure is written.
private final class Overtaker: @unchecked Sendable {
    var diagnostics: SilentTrackDiagnostics?
}
