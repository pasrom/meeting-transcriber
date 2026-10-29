@testable import AudioTapLib
import CoreAudio
import XCTest

/// Issue #803: with an output device that also has inputs, the aggregate hands
/// the IOProc the device's input buffer first and the tap's buffer last. Reading
/// the first one recorded the microphone as the app track.
@available(macOS 14.2, *)
final class TapBufferSelectionTests: XCTestCase {
    func testTheTapIsTheLastBuffer() {
        XCTAssertNil(AppAudioCapture.tapBufferIndex(bufferCount: 0))
        // Output-only device: the tap's buffer is the only one.
        XCTAssertEqual(AppAudioCapture.tapBufferIndex(bufferCount: 1), 0)
        // Device with one input stream (MOTU M2), then the tap.
        XCTAssertEqual(AppAudioCapture.tapBufferIndex(bufferCount: 2), 1)
        XCTAssertEqual(AppAudioCapture.tapBufferIndex(bufferCount: 3), 2)
    }

    func testItReadsTheTapBufferNotTheDeviceInput() {
        var deviceInput: [Float] = [0.1, 0.1, 0.1, 0.1]
        var tap: [Float] = [0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }

        deviceInput.withUnsafeMutableBytes { device in
            tap.withUnsafeMutableBytes { tapBytes in
                list[0] = AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(device.count), mData: device.baseAddress,
                )
                list[1] = AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress,
                )
                let selected = AppAudioCapture.tapBuffer(in: UnsafePointer(list.unsafeMutablePointer))

                XCTAssertEqual(selected?.mData, tapBytes.baseAddress)
                XCTAssertEqual(selected?.mDataByteSize, UInt32(tapBytes.count))
            }
        }
    }

    /// Issue #712 (the loopback form of #803): the layout verdict is what tells
    /// a field log whether the "tap is last" rule held on that setup.
    func testTheLayoutIsExpectedWhenTheTapFollowsTheAnchorInputs() {
        // Output-only anchor (built-in speakers): the tap is the only stream.
        XCTAssertEqual(layout(anchor: 0, aggregate: 1).verdict, .tapIsLast)
        // Teams loopback driver or a Loopback device: one input stream, then the tap.
        XCTAssertEqual(layout(anchor: 1, aggregate: 2).verdict, .tapIsLast)
    }

    func testTheLayoutIsUnexpectedWhenTheCountsDoNotAddUp() {
        // One stream, the anchor's own: nothing left for the tap.
        XCTAssertEqual(layout(anchor: 1, aggregate: 1).verdict, .unexpected)
        // More than one extra stream: "last" might not be the tap.
        XCTAssertEqual(layout(anchor: 1, aggregate: 3).verdict, .unexpected)
    }

    func testNoInputStreamAtAllIsItsOwnVerdict() {
        // An aggregate with no stream attached has no "last buffer" to mis-pick,
        // so the #712 ordering phrase would send a reader the wrong way.
        XCTAssertEqual(layout(anchor: 0, aggregate: 0).verdict, .noStreams)
        XCTAssertTrue(TapLayout.Verdict.noStreams.isWarning)
        XCTAssertFalse(TapLayout.Verdict.unknown.isWarning)
    }

    func testAFailedReadIsNotZeroInputs() {
        // A vanished anchor reads as a status, not as "no inputs"; folded into
        // 0 it would turn "one input, then the tap" into a warning.
        let anchorGone = TapLayout(anchorInputs: .failed(-4), aggregateInputs: .value(2))
        XCTAssertEqual(anchorGone.verdict, .unknown)
        // The one place the summary's wording is pinned.
        XCTAssertEqual(anchorGone.summary, "anchorInputs=?(-4) inputStreams=2")

        let aggregateGone = TapLayout(anchorInputs: .value(0), aggregateInputs: .failed(-4))
        XCTAssertEqual(aggregateGone.verdict, .unknown)
    }

    func testAMissingDeviceReadsAsFailedNotAsNoInputs() {
        // Through the real HAL against an object that does not exist, which is
        // what the anchor lookup yields once the device is gone.
        guard case .failed = inputStreamCountReading(deviceID: AudioObjectID(kAudioObjectUnknown)) else {
            XCTFail("a missing device must not report an input stream count")
            return
        }
    }

    private func layout(anchor: Int, aggregate: Int) -> TapLayout {
        TapLayout(anchorInputs: .value(anchor), aggregateInputs: .value(aggregate))
    }

    func testAnEmptyListYieldsNoBuffer() {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list.unsafeMutablePointer.pointee.mNumberBuffers = 0

        XCTAssertNil(AppAudioCapture.tapBuffer(in: UnsafePointer(list.unsafeMutablePointer)))
    }
}
