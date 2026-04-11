@testable import MeetingTranscriber
import XCTest

final class AudioMixerDelayTests: XCTestCase {
    private let sampleRate = 16000
    private let sampleCount = 16000 // 1 second at 16kHz

    private func mixWithDelay(
        _ micDelay: TimeInterval,
        trackSeconds: Int = 1,
    ) throws -> [Float] {
        let tmpDir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let appURL = tmpDir.appendingPathComponent("delay_app_\(id).wav")
        let micURL = tmpDir.appendingPathComponent("delay_mic_\(id).wav")
        let outURL = tmpDir.appendingPathComponent("delay_out_\(id).wav")
        defer {
            try? FileManager.default.removeItem(at: appURL)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        let count = sampleRate * trackSeconds
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.5, count: count),
            sampleRate: sampleRate,
            url: appURL,
        )
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.3, count: count),
            sampleRate: sampleRate,
            url: micURL,
        )

        try AudioMixer.mix(
            appAudioPath: appURL,
            micAudioPath: micURL,
            outputPath: outURL,
            micDelay: micDelay,
            sampleRate: sampleRate,
        )

        return try AudioMixer.loadAudioFileAsFloat32(url: outURL)
    }

    func testMixPositiveMicDelay() throws {
        let output = try mixWithDelay(0.2)
        let delaySamples = Int(0.2 * Double(sampleRate))
        XCTAssertGreaterThanOrEqual(output.count, sampleCount)
        XCTAssertLessThanOrEqual(output.count, sampleCount + delaySamples)
    }

    func testMixNegativeMicDelay() throws {
        let output = try mixWithDelay(-0.2)
        let delaySamples = Int(0.2 * Double(sampleRate))
        XCTAssertGreaterThanOrEqual(output.count, sampleCount)
        XCTAssertLessThanOrEqual(output.count, sampleCount + delaySamples)
    }

    func testMixZeroDelay() throws {
        let output = try mixWithDelay(0)
        XCTAssertEqual(output.count, sampleCount)
    }

    // MARK: - micDelay clamp (#99)

    func testMixExcessiveNegativeDelayDoesNotInflateDuration() throws {
        // Reproduce #99: 60s tracks with -50s delay.
        // Without fix: delaySamples=800k < trackSamples=960k → padding applied
        //   → app becomes 1,760,000 samples (110s) — ~1.83x bloat
        // With fix (±30s clamp): delay clamped to -30s → padding = 480k
        //   → app becomes 1,440,000 (90s) — within tolerance
        let trackSec = 60
        let trackSamples = sampleRate * trackSec
        let maxAcceptable = trackSamples + 31 * sampleRate
        let output = try mixWithDelay(-50, trackSeconds: trackSec)
        XCTAssertLessThanOrEqual(
            output.count,
            maxAcceptable,
            "50s negative delay on 60s track must be clamped (#99)",
        )
    }

    func testMixExcessivePositiveDelayDoesNotInflateDuration() throws {
        let trackSec = 60
        let trackSamples = sampleRate * trackSec
        let maxAcceptable = trackSamples + 31 * sampleRate
        let output = try mixWithDelay(50, trackSeconds: trackSec)
        XCTAssertLessThanOrEqual(
            output.count,
            maxAcceptable,
            "50s positive delay on 60s track must be clamped (#99)",
        )
    }
}
