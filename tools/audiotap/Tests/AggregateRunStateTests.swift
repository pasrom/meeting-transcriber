@testable import AudioTapLib
import CoreAudio
import XCTest

/// What the aggregate device and the output it is bound to render as in the
/// log (issue #693). The HAL reads need hardware; the rendering does not, and
/// a field report of "no buffers ever arrived" is only decidable if the
/// rendering keeps a failed read apart from a real zero.
final class AggregateRunStateTests: XCTestCase {
    private func state(
        running: ProcessOutputState.Reading<Bool>,
        outputID: ProcessOutputState.Reading<AudioObjectID> = .value(145),
        outputRate: ProcessOutputState.Reading<Int> = .value(24000),
    ) -> AggregateRunState {
        AggregateRunState(
            aggregateID: 211,
            isRunning: running,
            defaultOutputDeviceID: outputID,
            defaultOutputRate: outputRate,
        )
    }

    func testAHealthyReadRendersEveryField() {
        XCTAssertEqual(
            state(running: .value(false)).summary,
            "aggregate=211 running=false defaultOutput=145 defaultOutputRate=24000",
        )
    }

    func testAStoppedAggregateIsNotTheSameAsAFailedRead() {
        // The whole point of the line: "the aggregate is not running" is the
        // finding, "we could not ask" is not, and a reader must not draw the
        // first from the second.
        let stopped = state(running: .value(false))
        let unknown = state(running: .failed(-4))
        XCTAssertTrue(stopped.summary.contains("running=false"))
        XCTAssertTrue(unknown.summary.contains("running=?(-4)"))
        XCTAssertNotEqual(stopped.summary, unknown.summary)
    }

    func testAMissingAggregateReportsUnknownNotStopped() {
        // Through the real HAL against an object that does not exist, which is
        // the state a probe taken after the tap is gone asks about. Reporting
        // `running=false` here would let a reader conclude "the aggregate was
        // not running" from a question that was never answered.
        let state = AggregateRunProbe.read(aggregateID: AudioObjectID(kAudioObjectUnknown))
        guard case .failed = state.isRunning else {
            XCTFail("a missing aggregate must not report a running state")
            return
        }
    }

    func testAnUnreadableOutputDeviceIsDistinctFromDeviceZero() {
        // Device id 0 is kAudioObjectUnknown, which is a real answer meaning
        // "there is no default output"; a failed read is not that answer.
        let none = state(running: .value(true), outputID: .value(0))
        let failed = state(running: .value(true), outputID: .failed(560_947_818))
        XCTAssertTrue(none.summary.contains("defaultOutput=0"))
        XCTAssertTrue(failed.summary.contains("defaultOutput=?(560947818)"))
    }
}
