@testable import AudioTapLib
import CoreAudio
import Foundation
import os
import XCTest

/// That the capture lifecycle actually asks `SilentTrackDiagnostics` for the
/// scheduling. Without this the call sites in `AppAudioCapture` can be deleted
/// and every test in `NoFirstBufferProbeSchedulingTests` stays green.
///
/// `Clock` and `Reasons` are shared with that file.
@available(macOS 14.2, *)
final class NoFirstBufferProbeWiringTests: XCTestCase {
    func testStoppingACaptureDisarmsItsPendingProbes() {
        // The teardown call site, and the one with teeth: `stopCapture()` runs
        // `destroy()` a few statements later, so a deadline that survived it
        // would read an aggregate CoreAudio has removed and render a failed-read
        // marker into a field log as if it were a finding.
        let clock = ProbeClock()
        let reasons = ProbeReasons()
        let diagnostics = SilentTrackDiagnostics(
            probe: { _, _ in .init(processes: [], device: nil) },
            sink: { reason, _ in reasons.append(reason) },
            delayedWork: { clock.arm($0, $1) },
        )
        let capture = AppAudioCapture(
            pids: [1],
            outputFileDescriptor: -1,
            attemptBody: { nil },
            silentTrackDiagnostics: diagnostics,
        )

        diagnostics.scheduleNoBufferProbes([], aggregateID: 42, schedule: .init(offsets: [5]))
        XCTAssertEqual(clock.delays, [5], "precondition: one deadline is armed")

        capture.stopCapture()

        // On the items, for the reason given in the scheduling tests: an empty sink
        // is indistinguishable from a queue that has not run yet, and the sink
        // form of this assertion was green with the call site deleted.
        XCTAssertTrue(
            clock.items.allSatisfy(\.isCancelled),
            "stopCapture must disarm what startCapture armed",
        )
        clock.fireAll()
        XCTAssertEqual(reasons.all, [])
    }
}
