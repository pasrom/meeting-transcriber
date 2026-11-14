import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Runs an imported file through the real pipeline (resample, Parakeet,
/// FluidAudio diarization) for channel shapes the committed fixtures do not
/// have, and compares the result with the mono import of the same speech.
///
/// Why this exists: the format sweep in `WhisperKitE2ETests` covers containers
/// and codecs, and `AudioImportFidelityTests` covers what `resampleFile` writes,
/// but nothing checked what the stages after it make of a multi-channel import.
/// A two-channel file whose speakers sit on different channels once lost one
/// channel on the way to the transcript while every stage reported success, so
/// the assertions here are on the transcript: where in the recording it begins
/// and ends, and which speakers it names.
///
/// The shapes are synthesised from `two_speakers_de.wav` rather than committed:
/// the first half of the speech goes to the left channel only and the second
/// half to the right channel only. A pipeline that reads the left channel alone
/// produces a transcript that stops halfway, one that reads the right alone a
/// transcript that begins halfway, so both ends are asserted. Those two are the
/// checks that catch a lost channel. The speaker count does not, because both
/// voices talk in either half; it is there to show that diarization ran on the
/// import at all.
@MainActor
final class ImportChannelShapeE2ETests: XCTestCase {
    private struct Outcome {
        let speakers: Set<String>
        /// Start of the first and of the last transcript line, in seconds.
        let firstLineStart: Int
        let lastLineStart: Int
    }

    func testMonoImportCoversTheRecording() async throws {
        try skipIfCIWithoutE2EOptIn("requires Parakeet and FluidAudio models")
        let (samples, rate) = try await fixtureSamples()

        let outcome = try await importThroughPipeline(fixtureURL())

        assertCoversBothHalves(outcome, duration: Double(samples.count) / Double(rate), shape: "mono")
        XCTAssertEqual(outcome.speakers.count, 2, "the fixture has two speakers, got \(outcome.speakers)")
    }

    /// Already at the pipeline's rate, so the import takes whatever shortcut
    /// `resampleFile` has for sources that need no rate conversion.
    func testSplitStereoAtPipelineRateMatchesMono() async throws {
        try await assertSplitStereoMatchesMono(rate: AudioConstants.targetSampleRate)
    }

    /// Needs a rate conversion, so the import decodes and folds the channels.
    func testSplitStereoAt44kMatchesMono() async throws {
        try await assertSplitStereoMatchesMono(rate: 44100)
    }

    // MARK: - Helpers

    private func assertSplitStereoMatchesMono(rate: Int) async throws {
        try skipIfCIWithoutE2EOptIn("requires Parakeet and FluidAudio models")
        let (samples, sourceRate) = try await fixtureSamples()
        let duration = Double(samples.count) / Double(sourceRate)
        let atRate = sourceRate == rate ? samples : AudioMixer.resample(samples, from: sourceRate, to: rate)
        let source = try makeTempDirectory(prefix: "import_shape").appendingPathComponent("split_\(rate).wav")
        try writeSplitStereo(atRate, rate: rate, to: source)

        let outcome = try await importThroughPipeline(source)

        assertCoversBothHalves(outcome, duration: duration, shape: "split stereo at \(rate) Hz")
        XCTAssertEqual(
            outcome.speakers.count, 2,
            "split stereo at \(rate) Hz must name both speakers like the mono import, got \(outcome.speakers)",
        )
    }

    /// The speech is ~50 s and the speakers alternate through both halves, so a
    /// transcript of the whole recording has a line starting well before the
    /// middle and one starting well past it. The 40 % and 60 % marks leave room
    /// for a long first or last turn, which the transcript renders as one line.
    private func assertCoversBothHalves(_ outcome: Outcome, duration: Double, shape: String) {
        XCTAssertLessThan(
            Double(outcome.firstLineStart), duration * 0.4,
            "\(shape): the transcript begins at \(outcome.firstLineStart) s of \(Int(duration)) s, so the first half is missing",
        )
        XCTAssertGreaterThan(
            Double(outcome.lastLineStart), duration * 0.6,
            "\(shape): the transcript stops at \(outcome.lastLineStart) s of \(Int(duration)) s, so the second half is missing",
        )
    }

    private func fixtureSamples() async throws -> (samples: [Float], rate: Int) {
        let fixture = fixtureURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Fixture not found at \(fixture.path)")
        let (samples, rate) = try await AudioMixer.loadAudioAsFloat32(url: fixture)
        return (samples, rate)
    }

    /// First half on the left channel only, second half on the right only.
    private func writeSplitStereo(_ samples: [Float], rate: Int, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(rate),
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count),
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let half = samples.count / 2
        for (index, sample) in samples.enumerated() {
            channels[0][index] = index < half ? sample : 0
            channels[1][index] = index < half ? 0 : sample
        }
        try file.write(from: buffer)
    }

    private func importThroughPipeline(_ source: URL) async throws -> Outcome {
        let diarizer = FluidDiarizer()
        try XCTSkipUnless(diarizer.isAvailable, "FluidAudio diarization not available")
        let workDir = try makeTempDirectory(prefix: "import_shape_out")
        let protocolGen = MockProtocolGen()

        let queue = PipelineQueue(
            engine: ParakeetEngine(),
            diarizationFactory: { FluidDiarizer() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: workDir,
            logDir: workDir,
            stagingDir: workDir.appendingPathComponent("staging"),
            diarizeEnabled: true,
        )

        let done = XCTestExpectation(description: "job reaches a terminal state")
        queue.onJobStateChange = { _, _, newState in
            if newState == .done || newState == .error { done.fulfill() }
        }
        queue.enqueue(PipelineJob(
            meetingTitle: "Import shape",
            appName: "Import",
            mixPath: source,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            autoSkipNaming: true,
        ))
        await queue.processNext()
        await fulfillment(of: [done], timeout: 180)

        XCTAssertEqual(queue.jobs.first?.state, .done, "import failed: \(queue.jobs.first?.error ?? "no error text")")
        let transcript = try XCTUnwrap(protocolGen.capturedTranscript, "no transcript reached the protocol stage")
        return Self.parse(transcript)
    }

    /// Lines read `[MM:SS] S1: text`: with naming skipped and an empty speaker
    /// database every voice gets a short placeholder label. A line without one
    /// (diarization failed, which the pipeline survives) still counts for the
    /// coverage but names no speaker: a label is one word, so a colon further
    /// into the text, as in a time of day, is not taken for one.
    private static func parse(_ transcript: String) -> Outcome {
        var speakers = Set<String>()
        var first = Int.max
        var last = 0
        for line in transcript.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let clock = line[line.index(after: line.startIndex) ..< close].split(separator: ":").compactMap { Int($0) }
            let rest = line[line.index(after: close)...].dropFirst()
            guard clock.count == 2 else { continue }
            let start = clock[0] * 60 + clock[1]
            first = min(first, start)
            last = max(last, start)
            if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains(" ") {
                speakers.insert(String(rest[..<colon]))
            }
        }
        return Outcome(speakers: speakers, firstLineStart: first, lastLineStart: last)
    }
}
