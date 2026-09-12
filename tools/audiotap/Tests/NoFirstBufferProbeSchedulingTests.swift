@testable import AudioTapLib
import CoreAudio
import Foundation
import os
import XCTest

/// The scheduling half of the no-first-buffer probe: that one probe is armed
/// per offset, that the first buffer disarms all of them, and that a restart
/// replaces the previous arming rather than stacking on it.
///
/// The delay is injected rather than waited out. A test that sleeps past a real
/// five-second deadline to prove a probe fired would also have to sleep past it
/// to prove one did not, and the second half of that is a coin toss on a loaded
/// machine, not an assertion.
/// Captures what was armed instead of arming it, so the test decides when
/// each deadline is reached.
final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: [(TimeInterval, DispatchWorkItem)] = []

    var delays: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return armed.map(\.0)
    }

    var items: [DispatchWorkItem] {
        lock.lock(); defer { lock.unlock() }
        return armed.map(\.1)
    }

    func arm(_ delay: TimeInterval, _ item: DispatchWorkItem) {
        lock.lock(); defer { lock.unlock() }
        armed.append((delay, item))
    }

    /// Runs every armed item, cancelled ones included: `DispatchWorkItem`
    /// skips its body when cancelled, which is the behaviour under test.
    func fireAll() {
        lock.lock()
        let items = armed.map(\.1)
        lock.unlock()
        for item in items {
            item.perform()
        }
    }
}

final class ProbeReasons: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func append(_ reason: String) {
        lock.lock(); seen.append(reason); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }; return seen
    }
}

final class NoFirstBufferProbeSchedulingTests: XCTestCase {
    private func makeDiagnostics(clock: ProbeClock, reasons: ProbeReasons) -> SilentTrackDiagnostics {
        SilentTrackDiagnostics(
            probe: { _, aggregateID in
                .init(processes: [], device: AggregateRunState(
                    aggregateID: aggregateID,
                    isRunning: .value(false),
                    defaultOutputDeviceID: .value(7),
                    defaultOutputRate: .value(48000),
                ))
            },
            sink: { reason, _ in reasons.append(reason) },
            delayedWork: { clock.arm($0, $1) },
        )
    }

    func testOneProbeIsArmedPerOffset() {
        let clock = ProbeClock()
        let diagnostics = makeDiagnostics(clock: clock, reasons: ProbeReasons())
        diagnostics.scheduleNoBufferProbes([], aggregateID: 42, schedule: .production)
        XCTAssertEqual(clock.delays, NoFirstBufferProbeSchedule.production.offsets)
    }

    func testEachArmedProbeReportsItsOwnOffset() {
        let clock = ProbeClock()
        let reasons = ProbeReasons()
        let diagnostics = makeDiagnostics(clock: clock, reasons: reasons)
        diagnostics.scheduleNoBufferProbes([], aggregateID: 42, schedule: .init(offsets: [5, 30]))
        clock.fireAll()
        expectEventually(reasons, ["no buffers after 5 s", "no buffers after 30 s"])
    }

    func testTheFirstBufferDisarmsEveryPendingProbe() {
        // The whole reason a healthy recording emits nothing. Without this the
        // line fires on every recording whose far end is quiet for five seconds.
        let clock = ProbeClock()
        let reasons = ProbeReasons()
        let diagnostics = makeDiagnostics(clock: clock, reasons: reasons)
        diagnostics.scheduleNoBufferProbes([], aggregateID: 42, schedule: .init(offsets: [5, 30]))
        diagnostics.cancelNoBufferProbes()
        // Asserted on the work items, not on an empty sink. The sink hops to the
        // diagnostics queue, so "no reasons yet" is also what a queue that has
        // simply not run yet looks like, and the sink form of this assertion
        // passed with the cancellation deleted.
        XCTAssertTrue(clock.items.allSatisfy(\.isCancelled))
        clock.fireAll()
        XCTAssertEqual(reasons.all, [], "and nothing is reported once they do run")
    }

    func testArmingAgainDisarmsThePreviousSchedule() {
        // A device-change restart runs `startCapture()` again. Without this the
        // old attempt's deadlines keep firing against an aggregate that no
        // longer exists, and each rebuild would add three more.
        let clock = ProbeClock()
        let reasons = ProbeReasons()
        let diagnostics = makeDiagnostics(clock: clock, reasons: reasons)
        diagnostics.scheduleNoBufferProbes([], aggregateID: 42, schedule: .init(offsets: [5]))
        diagnostics.scheduleNoBufferProbes([], aggregateID: 99, schedule: .init(offsets: [30]))
        clock.fireAll()
        expectEventually(reasons, ["no buffers after 30 s"])
    }

    /// The probe itself hops to the diagnostics queue, so the sink lands after
    /// `perform()` returns.
    private func expectEventually(
        _ reasons: ProbeReasons, _ expected: [String], file: StaticString = #filePath, line: UInt = #line,
    ) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, reasons.all.count < expected.count {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(reasons.all.sorted(), expected.sorted(), file: file, line: line)
    }
}
