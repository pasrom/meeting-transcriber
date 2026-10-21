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

    func testAnEmptyListYieldsNoBuffer() {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list.unsafeMutablePointer.pointee.mNumberBuffers = 0

        XCTAssertNil(AppAudioCapture.tapBuffer(in: UnsafePointer(list.unsafeMutablePointer)))
    }
}
