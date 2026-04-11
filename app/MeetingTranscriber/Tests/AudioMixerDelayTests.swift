@testable import MeetingTranscriber
import XCTest

final class AudioMixerDelayTests: XCTestCase {
    private let sampleRate = 16000
    private let sampleCount = 16000 // 1 second at 16kHz

    private func mixWithDelay(_ micDelay: TimeInterval) throws -> [Float] {
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

        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.5, count: sampleCount),
            sampleRate: sampleRate,
            url: appURL,
        )
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.3, count: sampleCount),
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

    func testMixExcessivePositiveDelayIsClamped() throws {
        // 500s delay would double a 1s track — must be clamped to maxMicDelay
        let output = try mixWithDelay(500)
        let maxPad = Int(AudioMixer.maxMicDelay * Double(sampleRate))
        XCTAssertLessThanOrEqual(
            output.count,
            sampleCount + maxPad,
            "Excessive positive delay must be clamped",
        )
    }

    func testMixExcessiveNegativeDelayIsClamped() throws {
        // -500s delay would double a 1s track — must be clamped
        let output = try mixWithDelay(-500)
        let maxPad = Int(AudioMixer.maxMicDelay * Double(sampleRate))
        XCTAssertLessThanOrEqual(
            output.count,
            sampleCount + maxPad,
            "Excessive negative delay must be clamped",
        )
    }

    func testMaxMicDelayConstant() {
        XCTAssertEqual(
            AudioMixer.maxMicDelay,
            30,
            "maxMicDelay should be 30 seconds",
        )
    }
}
