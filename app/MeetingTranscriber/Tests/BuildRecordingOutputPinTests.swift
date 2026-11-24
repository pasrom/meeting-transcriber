import AudioTapLib
import CryptoKit
@testable import MeetingTranscriber
import XCTest

/// The bytes `buildRecording` writes, pinned by hash. Any change to how the
/// end of a recording holds or frees its buffers must leave every file it
/// writes exactly as it was: the mix, the app track and the microphone track,
/// for each branch (both tracks with either sign of delay, a resampled app
/// track, app only, microphone only).
///
/// The hashes were taken from the code before the buffers were released early.
/// A change to the audio itself (the echo gate, the alignment, the WAV writer)
/// also moves them; then the new values are pinned deliberately, never as a
/// side effect of a memory change.
final class BuildRecordingOutputPinTests: XCTestCase {
    private let stem = "20260311_140000"

    /// Both tracks at 16 kHz mono, the production capture format, the
    /// microphone starting 0.3 s after the app, so the echo gate and the
    /// alignment both act.
    func testTheDualTrackMixWithAPositiveDelayIsUnchanged() throws {
        let hashes = try build(
            app: EchoTestAudio.gatedBursts(seconds: 3, rate: 16000, channels: 1, seed: 1), appRate: 16000, appChannels: 1,
            mic: EchoTestAudio.gatedBursts(seconds: 3, rate: 16000, channels: 1, seed: 2), micDelay: 0.3,
        )
        XCTAssertEqual(hashes, [
            "mix": "96ad17867c122e87424a8bcf380d4a95facfc74429ef2d1d6e90ad1d0210f20f",
            "app": "b207e527fe5b6c5aa8a390211316999e3068fe5ad5aaaf70dbaab7f7e7547d61",
            "mic": "8cc74b9d8f272fa1ce56f9ab502a17dc902dac322dd05a96b62c41d671ff225a",
        ])
    }

    /// The microphone first, as it is on every dual-source recording now: the
    /// app track is padded on disk and the mixer is told there is no delay.
    func testTheDualTrackMixWithANegativeDelayIsUnchanged() throws {
        let hashes = try build(
            app: EchoTestAudio.gatedBursts(seconds: 3, rate: 16000, channels: 1, seed: 3), appRate: 16000, appChannels: 1,
            mic: EchoTestAudio.gatedBursts(seconds: 3, rate: 16000, channels: 1, seed: 4), micDelay: -0.25,
        )
        XCTAssertEqual(hashes, [
            "mix": "200ec4785cab2857e5bf6733acbbf0e8198a7a433f786a9dc22aea52c57f931e",
            "app": "70e40ad051819bd0faa1e45be391adef00f994eac8a0c016a3668c27ecfcb848",
            "mic": "62977852e172db9f1d8f3296915f891da480c8ed6a1f64fef533f9a9b76d9ab8",
        ])
    }

    /// The fallback path: a raw 48 kHz stereo temp that is downmixed and
    /// resampled before it is written.
    func testTheResampledDualTrackMixIsUnchanged() throws {
        let hashes = try build(
            app: EchoTestAudio.gatedBursts(seconds: 2, rate: 48000, channels: 2, seed: 5), appRate: 48000, appChannels: 2,
            mic: EchoTestAudio.gatedBursts(seconds: 2, rate: 16000, channels: 1, seed: 6), micDelay: 0.1,
        )
        XCTAssertEqual(hashes, [
            "mix": "7da0f44997e04abd23c2dbd08cc1acfcc2663ffe704d0be972891569b8d95608",
            "app": "308f1ab04aa61c8b95fc62657c04d8cea45c52c38488ea386d30ce25298de017",
            "mic": "6a4536f05c6f0622aac0d16b9f0d006dea67c34c2f51fce686cd451611eb85ab",
        ])
    }

    func testTheAppOnlyMixIsUnchanged() throws {
        let hashes = try build(
            app: EchoTestAudio.gatedBursts(seconds: 2, rate: 16000, channels: 1, seed: 7), appRate: 16000, appChannels: 1,
            mic: [], micDelay: 0,
        )
        XCTAssertEqual(hashes, [
            "mix": "3d4c44e69bfe88cc2c6ad60687beaf591851b3dfe403b0730403b14f1569c190",
            "app": "3d4c44e69bfe88cc2c6ad60687beaf591851b3dfe403b0730403b14f1569c190",
        ])
    }

    func testTheMicrophoneOnlyMixIsUnchanged() throws {
        let hashes = try build(
            app: [], appRate: 16000, appChannels: 1,
            mic: EchoTestAudio.gatedBursts(seconds: 2, rate: 16000, channels: 1, seed: 8), micDelay: 0,
        )
        XCTAssertEqual(hashes, [
            "mix": "f2ff4a361bb36cb6b7143f987588f73a34e2478a7b3014f728fd73caa8f8e277",
            "mic": "f2ff4a361bb36cb6b7143f987588f73a34e2478a7b3014f728fd73caa8f8e277",
        ])
    }

    // MARK: - Helpers

    /// Run `buildRecording` over the given tracks and hash every file it
    /// leaves, keyed by role.
    private func build(
        app: [Float], appRate: Int, appChannels: Int, mic: [Float], micDelay: TimeInterval,
    ) throws -> [String: String] {
        let dir = try makeTempDirectory(prefix: "build_pin")
        var appTmp: URL?
        if !app.isEmpty {
            let url = dir.appendingPathComponent("\(stem)\(RecordingFileSuffix.appRaw)")
            try writeRawFloat32(app, to: url)
            appTmp = url
        }
        var micWav: URL?
        if !mic.isEmpty {
            let url = dir.appendingPathComponent("\(stem)\(RecordingFileSuffix.mic)")
            try AudioMixer.saveWAV(samples: mic, sampleRate: 16000, url: url)
            micWav = url
        }

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: appRate, actualChannels: appChannels, micDelay: micDelay,
            ),
            recordingsDir: dir, timestamp: stem,
            recordingStartDate: Date(timeIntervalSince1970: 1000),
            format: CaptureFormat(requestedChannels: 1, requestedRate: 16000, targetRate: 16000),
        )

        var hashes = try ["mix": Self.sha256(of: result.mixPath)]
        if let path = result.appPath { hashes["app"] = try Self.sha256(of: path) }
        if let path = result.micPath { hashes["mic"] = try Self.sha256(of: path) }
        return hashes
    }

    private static func sha256(of url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
