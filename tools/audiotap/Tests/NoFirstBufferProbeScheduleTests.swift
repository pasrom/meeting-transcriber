@testable import AudioTapLib
import XCTest

/// When an app-audio capture that has delivered nothing gets probed, and what
/// the resulting line says.
///
/// Worth a value type of its own because the three probe points that shipped
/// with issue #693 cannot answer the question they were built for: `start`
/// lands before the microphone open that triggers the fault, `zero run started`
/// needs buffers to be arriving and so never fires here, and `stop` races the
/// teardown. This is the fourth, and the only one taken while the recording is
/// still running.
final class NoFirstBufferProbeScheduleTests: XCTestCase {
    func testTheProductionOffsetsStraddleTheKnownRecoveryTimes() {
        // The first has to clear a healthy start by a wide margin: a tap's first
        // buffer arrives about 30 to 60 ms after the device starts, and the
        // slowest first callback in the field logs was 0.78 s. The second has to
        // clear the benign case, an aggregate waiting under
        // `kAudioAggregateDeviceTapAutoStartKey` for a target that is playing
        // nothing, which was measured recovering by itself after the best part
        // of a minute. The third exists because a meeting can start in silence.
        XCTAssertEqual(NoFirstBufferProbeSchedule.production.offsets, [5, 30, 120])
    }

    func testTheOffsetsAreOrderedAndDistinct() {
        // They are rendered into the reason string, so two equal offsets would
        // produce two lines a reader cannot tell apart.
        let offsets = NoFirstBufferProbeSchedule.production.offsets
        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertEqual(Set(offsets).count, offsets.count)
    }

    func testTheReasonNamesTheElapsedTimeAndTheAbsenceOfBuffers() {
        // The reason is the only thing separating these lines from the three
        // that already exist, and the elapsed time is what makes a late start
        // ("no buffers after 5 s" alone, then delivery) distinguishable from one
        // that never came.
        XCTAssertEqual(NoFirstBufferProbeSchedule.production.reason(after: 5), "no buffers after 5 s")
        XCTAssertEqual(NoFirstBufferProbeSchedule.production.reason(after: 120), "no buffers after 120 s")
    }

    func testTheReasonDoesNotRenderAFractionForAWholeNumberOfSeconds() {
        // The offsets are whole seconds and the line is read by people, so
        // "5.0 s" would be noise. A schedule with a fractional offset, which
        // only a test uses, still has to render readably.
        XCTAssertEqual(NoFirstBufferProbeSchedule(offsets: [0.25]).reason(after: 0.25), "no buffers after 0.25 s")
    }
}
