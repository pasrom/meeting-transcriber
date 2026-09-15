import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// `buildRecording` end of the normalisation: that the pad reaches the file on
/// disk, that the mixer and the result are told the delay is gone, and that the
/// rate cross-check still sees the measured value.
final class BuildRecordingNormalisationTests: XCTestCase {
    private let format = CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000)

    func testANegativeDelayPadsTheAppTrackOnDiskAndReportsZero() throws {
        let dir = try makeTempDirectory(prefix: "norm_pad")
        let appTmp = dir.appendingPathComponent("20260311_140000_app_raw.tmp")
        // One second of 48 kHz stereo, so exactly 16000 samples after resampling.
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent("20260311_140000_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: 48000, actualChannels: 2, micDelay: -0.25,
            ),
            recordingsDir: dir, timestamp: "20260311_140000",
            recordingStartDate: Date(timeIntervalSince1970: 1000), format: format,
        )

        XCTAssertEqual(result.micDelay, 0, "the files are aligned, so nothing is left to shift")
        let app = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(result.appPath))
        XCTAssertEqual(app.count, 16000 + 4000)
        XCTAssertTrue(app.prefix(4000).allSatisfy { $0 == 0 }, "the lead is silence, not the track's own head")
        XCTAssertTrue(app.dropFirst(4000).allSatisfy { $0 != 0 }, "and the track itself is intact behind it")
    }

    func testANegativeDelayLeavesTheAppTrackAloneWithNoMicrophoneTrack() throws {
        // Without a second track there is nothing to align to, and these samples
        // go straight into an app-only mix. Padding there would prepend silence
        // for no reason at all.
        let dir = try makeTempDirectory(prefix: "norm_nomic")
        let appTmp = dir.appendingPathComponent("20260311_140000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: nil,
                actualSampleRate: 48000, actualChannels: 2, micDelay: -0.25,
            ),
            recordingsDir: dir, timestamp: "20260311_140000",
            recordingStartDate: Date(timeIntervalSince1970: 1000), format: format,
        )

        XCTAssertEqual(result.micDelay, -0.25, "and the measured value is still reported")
        let app = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(result.appPath))
        XCTAssertEqual(app.count, 16000)
    }

    func testTheRateCrossCheckStillSeesTheMeasuredDelayNotTheNormalisedOne() throws {
        // `crossCheckAppRate` derives `appDuration = micDuration + micDelay`,
        // which is correct for both signs against the *unpadded* file. Move the
        // normalisation above it and the zero it reports turns four seconds of
        // 48 kHz audio into an inferred 24 kHz, which then resamples to twice
        // the length. The lengths below are what tells those two apart.
        let dir = try makeTempDirectory(prefix: "norm_rate")
        let appTmp = dir.appendingPathComponent("20260311_140000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2 * 4), to: appTmp)
        let micWav = dir.appendingPathComponent("20260311_140000_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000 * 8), sampleRate: 16000, url: micWav)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: 48000, actualChannels: 2, micDelay: -4,
            ),
            recordingsDir: dir, timestamp: "20260311_140000",
            recordingStartDate: Date(timeIntervalSince1970: 1000), format: format,
        )

        let app = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(result.appPath))
        XCTAssertEqual(app.count, 4 * 16000 + 4 * 16000, "four seconds of audio behind four seconds of pad")
    }

    func testALeadLongerThanTheAppTrackIsStillPadded() throws {
        // `AudioMixer.mix` refuses to pad when the delay exceeds the track's own
        // length. That guard is deliberately not copied, and it has to be
        // asserted here rather than on the decision, which has no track length
        // to reject: adding `padFrames <= appSamples16k.count` to the builder
        // survives every test that lives on the pure type.
        let dir = try makeTempDirectory(prefix: "norm_long")
        let appTmp = dir.appendingPathComponent("20260311_140000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 16000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent("20260311_140000_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000 * 6), sampleRate: 16000, url: micWav)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: 16000, actualChannels: 2, micDelay: -5,
            ),
            recordingsDir: dir, timestamp: "20260311_140000",
            recordingStartDate: Date(timeIntervalSince1970: 1000), format: format,
        )

        let app = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(result.appPath))
        XCTAssertEqual(app.count, 5 * 16000 + 16000, "five seconds of lead on a one-second track")
    }

    func testTheThreeFilesEndUpOnOneOrigin() throws {
        // The acceptance test, and it falsifies the rationale rather than the
        // mechanism: an event that happened at one instant has to land at the
        // same offset in the app track, the microphone track and the mix.
        //
        // The microphone led by 0.25 s, so a sound at 1.00 s of real time sits
        // at 1.00 s in the microphone file and at 0.75 s in the app file as
        // captured. After normalisation both must read 1.00 s.
        let dir = try makeTempDirectory(prefix: "norm_origin")
        let rate = 16000
        let appTmp = dir.appendingPathComponent("20260311_140000_app_raw.tmp")
        var appRaw = [Float](repeating: 0, count: rate * 2 * 2)
        for channel in 0 ..< 2 {
            appRaw[Int(0.75 * Double(rate)) * 2 + channel] = 1
        }
        try writeRawFloat32(appRaw, to: appTmp)

        // The microphone's impulse is deliberately the quieter of the two. The
        // mix averages both tracks, so two of equal height tie and `peakIndex`
        // returns the earlier one, which is the microphone's; the app impulse
        // could then move anywhere in the mix and the assertion would not see
        // it. That is why the first version of this test stayed green when the
        // mixer was handed the measured delay.
        let micWav = dir.appendingPathComponent("20260311_140000_mic.wav")
        var mic = [Float](repeating: 0, count: rate * 2)
        mic[rate] = 0.3
        try AudioMixer.saveWAV(samples: mic, sampleRate: rate, url: micWav)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: rate, actualChannels: 2, micDelay: -0.25,
            ),
            recordingsDir: dir, timestamp: "20260311_140000",
            recordingStartDate: Date(timeIntervalSince1970: 1000), format: format,
        )

        let app = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(result.appPath))
        let mix = try AudioMixer.loadAudioFileAsFloat32(url: result.mixPath)
        XCTAssertEqual(peakIndex(app), Double(rate), accuracy: 1, "app impulse moved onto the shared origin")
        // The assertion with teeth, and it was missing: this test claimed three
        // files and read two. Hand the mixer the measured delay instead of the
        // normalised one and it pads an already-padded track a second time,
        // putting the app impulse at 1.25 s against a transcript that says
        // 1.00 s. That is the snippet-arrives-early failure this change exists
        // to remove, and every other test stayed green under it.
        XCTAssertEqual(peakIndex(mix), Double(rate), accuracy: 1, "and the mix agrees with both of them")
        XCTAssertEqual(result.micDelay, 0)
    }

    private func peakIndex(_ samples: [Float]) -> Double {
        var best = 0
        for (index, value) in samples.enumerated() where abs(value) > abs(samples[best]) {
            best = index
        }
        return Double(best)
    }
}
