import Foundation
import XCTest

@testable import AudioTapLib

final class AudioCaptureResultTests: XCTestCase {
    func testFieldsStored() {
        let appURL = URL(fileURLWithPath: "/tmp/app.raw")
        let micURL = URL(fileURLWithPath: "/tmp/mic.wav")
        let result = AudioCaptureResult(
            appAudioFileURL: appURL,
            micAudioFileURL: micURL,
            actualSampleRate: 48000,
            actualChannels: 2,
            micDelay: 0.123
        )

        XCTAssertEqual(result.appAudioFileURL, appURL)
        XCTAssertEqual(result.micAudioFileURL, micURL)
        XCTAssertEqual(result.actualSampleRate, 48000)
        XCTAssertEqual(result.actualChannels, 2)
        XCTAssertEqual(result.micDelay, 0.123, accuracy: 1e-9)
    }

    func testNilMicURL() {
        let result = AudioCaptureResult(
            appAudioFileURL: URL(fileURLWithPath: "/tmp/app.raw"),
            micAudioFileURL: nil,
            actualSampleRate: 16000,
            actualChannels: 2,
            micDelay: 0
        )

        XCTAssertNil(result.micAudioFileURL)
        XCTAssertEqual(result.micDelay, 0)
    }

    func testMonoChannelCount() {
        let result = AudioCaptureResult(
            appAudioFileURL: URL(fileURLWithPath: "/tmp/app.raw"),
            micAudioFileURL: nil,
            actualSampleRate: 16000,
            actualChannels: 1,
            micDelay: 0
        )

        XCTAssertEqual(result.actualChannels, 1)
    }
}
