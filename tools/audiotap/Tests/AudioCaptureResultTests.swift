@testable import AudioTapLib
import XCTest

final class AudioCaptureResultTests: XCTestCase {
    func testResultStoresMonoChannels() {
        let result = AudioCaptureResult(
            appAudioFileURL: URL(fileURLWithPath: "/tmp/test.raw"),
            micAudioFileURL: nil,
            actualSampleRate: 48000,
            actualChannels: 1,
            micDelay: 0,
        )
        XCTAssertEqual(result.actualChannels, 1)
    }

    func testResultStoresStereoChannels() {
        let result = AudioCaptureResult(
            appAudioFileURL: URL(fileURLWithPath: "/tmp/test.raw"),
            micAudioFileURL: nil,
            actualSampleRate: 48000,
            actualChannels: 2,
            micDelay: 0,
        )
        XCTAssertEqual(result.actualChannels, 2)
    }
}
