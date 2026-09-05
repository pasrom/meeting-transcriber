@testable import AudioTapLib
import CoreAudio
import XCTest

/// What a tapped process's output state renders as in the log (issue #672).
/// The HAL reads themselves need hardware; the rendering does not, and the
/// rendering is where a diagnostic becomes readable or useless.
final class ProcessOutputStateTests: XCTestCase {
    private let process = TappedProcess(pid: 3497, audioObjectID: 91)

    private func state(
        running: ProcessOutputState.Reading<Bool>,
        devices: ProcessOutputState.Reading<[AudioObjectID]>,
    ) -> ProcessOutputState {
        ProcessOutputState(process: process, isRunningOutput: running, outputDevices: devices)
    }

    func testAHealthyReadRendersEveryField() {
        XCTAssertEqual(
            state(running: .value(true), devices: .value([73])).summary,
            "pid=3497 object=91 isRunningOutput=true outputDevices=[73]",
        )
    }

    func testSeveralOutputDevicesAreAllListed() {
        // The distinction the field case turns on: output going to a separate
        // aggregate rather than straight to the output device.
        let summary = state(running: .value(true), devices: .value([73, 512])).summary
        XCTAssertTrue(summary.contains("outputDevices=[73, 512]"))
    }

    func testNoOutputDeviceIsNotTheSameAsAFailedRead() {
        // "The process output went nowhere" and "we could not find out" are
        // different findings, and a log that rendered both as empty would let a
        // reader draw the first conclusion from the second.
        let none = state(running: .value(false), devices: .value([]))
        let failed = state(running: .value(false), devices: .failed(-4))
        XCTAssertTrue(none.summary.contains("outputDevices=[]"))
        XCTAssertTrue(failed.summary.contains("outputDevices=?(-4)"))
        XCTAssertNotEqual(none.summary, failed.summary)
    }

    func testEachReadingCarriesItsOwnFailure() {
        // A stored object id whose process has exited fails both reads, and that
        // is itself the finding: the tap has nothing left to follow. One
        // property the OS does not implement fails alone, and the other's value
        // must survive that.
        XCTAssertEqual(
            state(running: .failed(-4), devices: .failed(-4)).summary,
            "pid=3497 object=91 isRunningOutput=?(-4) outputDevices=?(-4)",
        )
        XCTAssertEqual(
            state(running: .value(true), devices: .failed(2003)).summary,
            "pid=3497 object=91 isRunningOutput=true outputDevices=?(2003)",
        )
    }

    func testTheSummaryCarriesNothingPersonal() {
        // Every field is a number or a boolean. Executable names are added by
        // the call site, which already logs them unconditionally for the same
        // triage reason; device names and bundle ids are gated elsewhere and
        // stay out of here. No path is interpolated, so the username leak that
        // String(describing:) causes on URLs cannot happen here.
        let summary = state(running: .value(true), devices: .value([73])).summary
        XCTAssertFalse(summary.contains("/"))
        XCTAssertFalse(summary.contains("Users"))
    }
}
