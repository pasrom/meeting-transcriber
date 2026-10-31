import AudioTapLib
@testable import MeetingTranscriber
import os
import XCTest

/// The microphone permission probe under a deadline (issue #778): the
/// verdict a probe that did not answer leads to, and the lane that bounds
/// the engine bring-up. The bring-up itself needs a microphone and is not
/// run here; the lane is exercised with a block that parks on a semaphore,
/// which is what a wedged `-[AVAudioEngine inputNode]` looks like from the
/// outside.
@MainActor
final class MicProbeDeadlineTests: XCTestCase {
    // MARK: - Verdict (pure)

    func testProbeDeadlineIsTheFirstStartDeadline() {
        // One number for the two paths through the same call, so the user
        // never sees the probe wait longer than the start it is meant to clear.
        XCTAssertEqual(
            PermissionHealthCheck.probeStartDeadline,
            TimeInterval(MicStartLimits.firstStartDeadlineSeconds),
        )
    }

    func testAProbeThatDidNotAnswerIsNotEvidenceAgainstTheGrant() {
        // `.broken` would tell the user to toggle a grant that is fine and would
        // refuse a manual recording that the recorder can still start without
        // the microphone under its own deadline.
        XCTAssertEqual(
            PermissionHealthCheck.microphoneVerdict(afterAuthorizedProbe: .didNotAnswer, lastAnswered: nil),
            .healthy,
        )
    }

    func testAProbeThatDidNotAnswerKeepsTheLastAnsweredVerdict() {
        // A probe that learned nothing changes nothing: a microphone last seen
        // broken stays broken rather than being reported recovered, which would
        // clear the badge and re-notify the same problem on the next answer.
        XCTAssertEqual(
            PermissionHealthCheck.microphoneVerdict(afterAuthorizedProbe: .didNotAnswer, lastAnswered: .broken),
            .broken,
        )
        XCTAssertEqual(
            PermissionHealthCheck.microphoneVerdict(afterAuthorizedProbe: .didNotAnswer, lastAnswered: .healthy),
            .healthy,
        )
    }

    func testAnAnsweredProbeKeepsTheBufferVerdict() {
        XCTAssertEqual(
            PermissionHealthCheck.microphoneVerdict(afterAuthorizedProbe: .answered(bufferCount: 0), lastAnswered: .healthy),
            .broken,
        )
        XCTAssertEqual(
            PermissionHealthCheck.microphoneVerdict(afterAuthorizedProbe: .answered(bufferCount: 3), lastAnswered: .broken),
            .healthy,
        )
    }

    // MARK: - Bring-up kernel

    func testABringUpThatReturnsInTimeIsHandedBack() async {
        let discarded = Recorded()
        let built = await PermissionHealthCheck.awaitBringUp(
            deadline: 2.0,
            on: BringUpLane(label: "test.mic-probe.prompt"),
            bringUp: { 42 },
            discardLate: { discarded.record($0) },
        )
        XCTAssertEqual(built, 42)
        XCTAssertEqual(discarded.values, [])
    }

    func testABringUpThatDoesNotReturnInTimeIsReportedAsNoneAndDiscardedLater() async {
        // Judged by an event: the wait has to answer while the bring-up is
        // still parked on a semaphore only the test releases.
        let gate = DispatchSemaphore(value: 0)
        let discarded = Recorded()
        let startedAt = ContinuousClock.now
        let call = Task {
            await PermissionHealthCheck.awaitBringUp(
                deadline: 0.2,
                on: BringUpLane(label: "test.mic-probe.wedged"),
                bringUp: { gate.wait(); return 7 },
                discardLate: { discarded.record($0) },
            )
        }
        guard let built = await value(of: call) else {
            gate.signal()
            XCTFail("the wait ends at the deadline, not when the call returns")
            return
        }
        XCTAssertNil(built, "a bring-up that has not returned is reported as none")
        // A lower bound, which a slow runner cannot break: not cut short.
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - startedAt, .milliseconds(200))
        XCTAssertEqual(discarded.values, [], "nothing came back yet, so there is nothing to discard")

        // The call returns later: what it built goes to the discard, not to
        // a caller that has long moved on.
        gate.signal()
        await waitFor(discarded.values == [7], timeout: regressionCeiling)
        XCTAssertEqual(discarded.values, [7])
    }

    func testABringUpQueuedBehindAWedgedOneTimesOutWithoutEnteringTheCall() async {
        // The production lane is serial on purpose: once one bring-up is
        // wedged, the next probe reports none at its deadline without running
        // its own bring-up, so the process loses one thread to the wedge, not
        // one per probe. Runs on a lane of its own, built the way the
        // production lane is, so a concurrent queue there would be caught and
        // a probe from elsewhere in the run cannot queue into this one; the
        // wedge is released at the end.
        let gate = DispatchSemaphore(value: 0)
        let discarded = Recorded()
        let entered = Recorded()
        // The wedged bring-up gets a deadline no run reaches, so the second is
        // always enqueued behind it rather than refused for an overrun (the
        // next test), however slowly the runner gets to the second call.
        let lane = BringUpLane(label: "test.mic-probe.queued")
        async let wedged: Int? = PermissionHealthCheck.awaitBringUp(
            deadline: 3600,
            on: lane,
            bringUp: { entered.record(1); gate.wait(); return 1 },
            discardLate: { discarded.record($0) },
        )
        // The wedged bring-up has the queue before the next one is enqueued.
        await waitFor(entered.values == [1], timeout: regressionCeiling)
        XCTAssertEqual(entered.values, [1])
        let second = await PermissionHealthCheck.awaitBringUp(
            deadline: 0.2,
            on: lane,
            bringUp: { entered.record(2); return 2 },
            discardLate: { discarded.record($0) },
        )
        XCTAssertNil(second)
        XCTAssertEqual(entered.values, [1], "the second bring-up must not have run behind the wedged one")

        // Released, the first returns within its own deadline and is handed
        // back; the second runs only now, after its deadline, and is discarded.
        gate.signal()
        let first = await wedged
        XCTAssertEqual(first, 1)
        await waitFor(discarded.values == [2], timeout: regressionCeiling)
        XCTAssertEqual(entered.values, [1, 2], "the second bring-up ran only after the wedge was released")
        XCTAssertEqual(discarded.values, [2], "the late return releases what it built")
    }

    func testABringUpBehindAnOverrunOneIsRefusedAtOnceUntilTheOverrunReturns() async {
        // Once a bring-up has outlived its own deadline and still not returned,
        // the lane is wedged: a probe arriving now would only queue another
        // engine behind the wedge and make its caller wait the full deadline
        // for an answer that is already known. It is refused at once instead,
        // and nothing is enqueued, so the late return has nothing extra to
        // tear down. The lane reopens when the overrun call returns.
        let gate = DispatchSemaphore(value: 0)
        let discarded = Recorded()
        let entered = Recorded()
        let lane = BringUpLane(label: "test.mic-probe.overrun")
        let overrun = await PermissionHealthCheck.awaitBringUp(
            deadline: 0.2,
            on: lane,
            bringUp: { entered.record(1); gate.wait(); return 1 },
            discardLate: { discarded.record($0) },
        )
        XCTAssertNil(overrun)

        // A deadline no run reaches: answering while the lane is still wedged
        // can only be the refusal itself.
        let refusal = Task {
            await PermissionHealthCheck.awaitBringUp(
                deadline: 3600,
                on: lane,
                bringUp: { entered.record(2); return 2 },
                discardLate: { discarded.record($0) },
            )
        }
        guard let refused = await value(of: refusal) else {
            gate.signal()
            XCTFail("refused at once, not at its deadline")
            return
        }
        XCTAssertNil(refused)

        gate.signal()
        await waitFor(discarded.values == [1], timeout: regressionCeiling)
        XCTAssertEqual(entered.values, [1], "the refused bring-up was never enqueued")

        let reopened = await PermissionHealthCheck.awaitBringUp(
            deadline: 2.0,
            on: lane,
            bringUp: { entered.record(3); return 3 },
            discardLate: { discarded.record($0) },
        )
        XCTAssertEqual(reopened, 3, "the lane reopens once the overrun call has returned")
        XCTAssertEqual(discarded.values, [1])
    }

    func testTheLaneStaysWedgedUntilTheLateReturnIsDiscarded() async {
        // The discard tears the late engine down on the lane's queue, on the
        // device that just wedged; a probe must not be let onto the queue
        // behind that teardown just because the bring-up itself returned.
        let gate = DispatchSemaphore(value: 0)
        let discarding = DispatchSemaphore(value: 0)
        let entered = Recorded()
        let discarded = Recorded()
        let lane = BringUpLane(label: "test.mic-probe.late-discard")
        let overrun = await PermissionHealthCheck.awaitBringUp(
            deadline: 0.2,
            on: lane,
            bringUp: { gate.wait(); return 1 },
            discardLate: { entered.record($0); discarding.wait(); discarded.record($0) },
        )
        XCTAssertNil(overrun)
        XCTAssertTrue(lane.isWedged)

        gate.signal()
        await waitFor(entered.values == [1], timeout: regressionCeiling)
        XCTAssertTrue(lane.isWedged, "the late engine is still being torn down on the lane")

        discarding.signal()
        await waitFor(discarded.values == [1], timeout: regressionCeiling)
        await waitFor(!lane.isWedged, timeout: regressionCeiling)
        XCTAssertFalse(lane.isWedged)
    }
}

/// Records integers handed to it from any thread, in order.
private final class Recorded: Sendable {
    private let recorded = OSAllocatedUnfairLock<[Int]>(initialState: [])

    var values: [Int] {
        recorded.withLock { $0 }
    }

    func record(_ value: Int) {
        recorded.withLock { $0.append(value) }
    }
}
