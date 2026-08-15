import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// File-level echo-suppression tests (`AudioMixer.suppressEchoInFile`) — the
/// wrapper that gates the mic 16 kHz track in place before transcription and
/// diarization when `dualTrackMicEchoSuppressionEnabled` is on (issue #422).
final class AudioMixerEchoSuppressionFileTests: XCTestCase {
    private func tempWAV(_ samples: [Float], sampleRate: Int = 16000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixer-test-\(UUID().uuidString).wav")
        try AudioMixer.saveWAV(samples: samples, sampleRate: sampleRate, url: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSuppressEchoInFileGatesMicAndPersists() throws {
        let sampleRate = 16000
        let windowSize = sampleRate / 50 // 320, same 20ms windows as suppressEcho
        let windowCount = 40

        // App energy in window 20 → gate spans windows 18...30 (2 before, 10 after).
        var appSamples = [Float](repeating: 0, count: windowCount * windowSize)
        for j in (20 * windowSize) ..< (21 * windowSize) {
            appSamples[j] = 1.0
        }
        // Mic carries 0.5 everywhere plus louder "double-talk" speech in window 20 —
        // the gate is a hard zero, so genuine simultaneous mic speech is dropped
        // too. That trade-off is the documented behavior, mirrored from mix().
        var micSamples = [Float](repeating: 0.5, count: windowCount * windowSize)
        for j in (20 * windowSize) ..< (21 * windowSize) {
            micSamples[j] = 0.9
        }

        let appURL = try tempWAV(appSamples, sampleRate: sampleRate)
        let micURL = try tempWAV(micSamples, sampleRate: sampleRate)

        try AudioMixer.suppressEchoInFile(
            appURL: appURL, micURL: micURL, sampleRate: sampleRate,
        )

        // Reload from disk — the rewrite must be persisted, not in-memory only.
        let reloaded = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
        XCTAssertEqual(reloaded.count, micSamples.count)
        func micWindow(_ w: Int) -> Float {
            reloaded[w * windowSize]
        }
        XCTAssertEqual(micWindow(17), 0.5, accuracy: 0.01, "below the gate stays untouched")
        XCTAssertEqual(micWindow(18), 0.0, "first gated window")
        XCTAssertEqual(micWindow(20), 0.0, "double-talk window is gated too (documented trade-off)")
        XCTAssertEqual(micWindow(30), 0.0, "last gated window")
        XCTAssertEqual(micWindow(31), 0.5, accuracy: 0.01, "above the gate stays untouched")
    }

    func testSuppressEchoInFileEmptyAppTrackIsNoOp() throws {
        // A dead/silent app channel yields a zero-frame WAV; gating against it
        // must leave the mic file untouched instead of rewriting it.
        let sampleRate = 16000
        let appURL = try tempWAV([], sampleRate: sampleRate)
        let micSamples = [Float](repeating: 0.5, count: sampleRate)
        let micURL = try tempWAV(micSamples, sampleRate: sampleRate)

        try AudioMixer.suppressEchoInFile(
            appURL: appURL, micURL: micURL, sampleRate: sampleRate,
        )

        let reloaded = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
        XCTAssertEqual(reloaded.count, micSamples.count)
        XCTAssertEqual(reloaded[0], 0.5, accuracy: 0.01, "mic content survives an empty app track")
    }

    func testSuppressEchoInFileClampsExcessiveMicDelay() throws {
        // 35s of audio; app energy at window 10 (gate app windows 8...20).
        // micDelay = -100s is beyond maxMicDelay (30s). Unclamped it would map the
        // gate to mic windows ~5008..., outside the file — nothing gated. Clamped
        // to -30s (delayWindows = -1500) the gate lands on mic windows 1508...1520,
        // so a zeroed window 1508 proves the file path clamps like mix() does.
        let sampleRate = 16000
        let windowSize = sampleRate / 50
        let windowCount = 1750

        var appSamples = [Float](repeating: 0, count: windowCount * windowSize)
        for j in (10 * windowSize) ..< (11 * windowSize) {
            appSamples[j] = 1.0
        }
        let micSamples = [Float](repeating: 0.5, count: windowCount * windowSize)

        let appURL = try tempWAV(appSamples, sampleRate: sampleRate)
        let micURL = try tempWAV(micSamples, sampleRate: sampleRate)

        try AudioMixer.suppressEchoInFile(
            appURL: appURL, micURL: micURL, sampleRate: sampleRate, micDelay: -100,
        )

        let reloaded = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
        func micWindow(_ w: Int) -> Float {
            reloaded[w * windowSize]
        }
        XCTAssertEqual(micWindow(1500), 0.5, accuracy: 0.01, "below the clamped gate stays untouched")
        XCTAssertEqual(micWindow(1508), 0.0, "clamped delay lands the gate inside the file")
        XCTAssertEqual(micWindow(1521), 0.5, accuracy: 0.01, "above the clamped gate stays untouched")
    }
}
