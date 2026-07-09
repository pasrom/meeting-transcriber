@testable import AudioTapLib
import Foundation
import XCTest

final class AudioCaptureResultTests: XCTestCase {
    func testFieldsStored() {
        let appURL = URL(fileURLWithPath: "/tmp/app.raw")
        let micURL = URL(fileURLWithPath: "/tmp/mic.wav")
        let result = AudioCaptureResult(
            appAudioFileURL: appURL,
            micAudioFileURL: micURL,
            actualSampleRate: 48000,
            actualChannels: 2,
            micDelay: 0.123,
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
            micDelay: 0,
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
            micDelay: 0,
        )

        XCTAssertEqual(result.actualChannels, 1)
    }

    // MARK: - AudioCaptureResult.make (stop() delay/rate/channel arithmetic)

    private static let appURL = URL(fileURLWithPath: "/tmp/app.raw")
    private static let micURL = URL(fileURLWithPath: "/tmp/mic.wav")

    private func make(
        micRecorded: Bool = true,
        appTicks: UInt64 = 1000,
        micTicks: UInt64 = 5000,
        appRate: Int = 16000,
        appChannels: Int = 1,
        configuredRate: Int = 48000,
        configuredChannels: Int = 2,
    ) -> AudioCaptureResult {
        AudioCaptureResult.make(
            appOutputURL: Self.appURL,
            micOutputURL: Self.micURL,
            configured: (sampleRate: configuredRate, channels: configuredChannels),
            app: .init(firstFrameTicks: appTicks, sampleRate: appRate, channels: appChannels),
            mic: .init(recorded: micRecorded, firstFrameTicks: micTicks),
        )
    }

    func testMakePositiveMicDelayWhenMicStartsLater() {
        // mic ticks > app ticks → mic started later → positive delay. Pins the
        // subtraction order (a sign flip is the #99 "mix.wav 2× duration" class).
        let result = make(appTicks: 1000, micTicks: 5000)
        XCTAssertGreaterThan(result.micDelay, 0)
        XCTAssertEqual(
            result.micDelay,
            machTicksToSeconds(5000) - machTicksToSeconds(1000),
            accuracy: 1e-12,
        )
    }

    func testMakeNegativeMicDelayWhenMicStartsEarlier() {
        XCTAssertLessThan(make(appTicks: 5000, micTicks: 1000).micDelay, 0)
    }

    func testMakeZeroDelayWhenAppNeverDeliveredAFrame() {
        // app tick 0 (no app frame) → the guard skips the delta, no bogus delay.
        XCTAssertEqual(make(appTicks: 0, micTicks: 5000).micDelay, 0)
    }

    func testMakeZeroDelayWhenMicNeverDeliveredAFrame() {
        XCTAssertEqual(make(appTicks: 1000, micTicks: 0).micDelay, 0)
    }

    func testMakeZeroDelayAndNilMicURLWhenMicNotRecorded() {
        // Valid ticks but no mic recorded → no delay and no mic URL.
        let result = make(micRecorded: false, appTicks: 1000, micTicks: 5000)
        XCTAssertEqual(result.micDelay, 0)
        XCTAssertNil(result.micAudioFileURL)
    }

    func testMakeIncludesMicURLWhenRecorded() {
        XCTAssertEqual(make(micRecorded: true).micAudioFileURL, Self.micURL)
    }

    func testMakeFallsBackToConfiguredRateWhenAppReportedZero() {
        XCTAssertEqual(make(appRate: 0, configuredRate: 48000).actualSampleRate, 48000)
    }

    func testMakeUsesAppReportedRateWhenNonZero() {
        XCTAssertEqual(make(appRate: 16000, configuredRate: 48000).actualSampleRate, 16000)
    }

    func testMakeFallsBackToConfiguredChannelsWhenAppReportedZero() {
        XCTAssertEqual(make(appChannels: 0, configuredChannels: 2).actualChannels, 2)
    }

    func testMakeUsesAppReportedChannelsWhenNonZero() {
        XCTAssertEqual(make(appChannels: 1, configuredChannels: 2).actualChannels, 1)
    }
}
