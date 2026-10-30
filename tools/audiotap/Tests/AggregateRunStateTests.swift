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
        inputStreams: ProcessOutputState.Reading<Int> = .value(1),
    ) -> AggregateRunState {
        AggregateRunState(
            aggregateID: 211,
            isRunning: running,
            defaultOutputDeviceID: outputID,
            defaultOutputRate: outputRate,
            inputStreams: inputStreams,
        )
    }

    func testAHealthyReadRendersEveryField() {
        XCTAssertEqual(
            state(running: .value(false)).summary,
            "aggregate=211 running=false defaultOutput=145 defaultOutputRate=24000 inputStreams=1",
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

    func testAPresentDeviceAnswersItsInputStreamCount() throws {
        // The `.value` branch through the real HAL: a device that exists
        // answers a count, 0 included, rather than refusing the input scope.
        // On most Macs the default output (the built-in speakers) is
        // output-only, the layout the "tap is last" rule was first measured on.
        guard case let .value(deviceID) = defaultOutputDeviceReading(), deviceID != kAudioObjectUnknown else {
            throw XCTSkip("no default output device on this machine")
        }
        guard case .value = inputStreamCountReading(deviceID: deviceID) else {
            XCTFail("a present device must answer its input stream count")
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
