import Foundation
@testable import MeetingTranscriber
import XCTest

@MainActor
extension XCTestCase {
    /// Returns once every completed-job removal timer `queue` has armed so far
    /// has fired, for a test whose job's expiry leaves nothing to observe: a
    /// job that must stay, or one held back while a menu is open. It arms the
    /// same timer for a probe job without an export, which nothing holds back,
    /// and waits for the probe to go.
    ///
    /// Two probes, one after the other: the first is armed right behind the
    /// test's own timer, and two sleeps that close together are not
    /// guaranteed to resume in the order they were armed. The second is armed
    /// only once the first is gone, so its deadline lies a full lifetime after
    /// that of every timer armed before the call. That is a margin, not an
    /// order the scheduler promises.
    func awaitArmedExpiryTimers(of queue: PipelineQueue, timeout: Duration) async {
        for index in 1 ... 2 {
            let probe = PipelineJob(
                meetingTitle: "Expiry probe \(index)", appName: "Zoom",
                mixPath: queue.logDir.appendingPathComponent("expiry_probe_\(index).wav"),
                appPath: nil, micPath: nil, micDelay: 0,
            )
            queue.enqueue(probe)
            queue.updateJobState(id: probe.id, to: .done)
            await waitFor({ !queue.jobs.contains { $0.id == probe.id } }, timeout: timeout)
            XCTAssertFalse(
                queue.jobs.contains { $0.id == probe.id },
                "Expiry probe \(index) was not removed, so the timers armed before it may not have fired",
            )
        }
    }
}
