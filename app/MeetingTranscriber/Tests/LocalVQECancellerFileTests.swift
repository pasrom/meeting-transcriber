// Tests for the file-to-file half of the EchoCancelling seam. The array form
// is the engine; this is the shape the pipeline actually calls, and the reason
// it exists is memory: at 16 kHz Float32 a 90 minute track is ~345 MB, and the
// array call holds microphone, reference and output at once.
//
// Model-gated like LocalVQECancellerTests: set
// MEETINGTRANSCRIBER_LOCALVQE_MODEL to a .gguf, or these skip.
@testable import MeetingTranscriber
import XCTest

final class LocalVQECancellerFileTests: XCTestCase {
    private var workDir = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aecfile_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Median reduction over the windows that carried a reference signal.
    ///
    /// The floor mirrors the one the self-check uses in production and is
    /// repeated rather than imported: this file tests the seam, and pinning it
    /// to a constant that belongs to a policy would tie the two together for
    /// no reason beyond convenience.
    private func activeMedianReduction(_ report: EchoCancellationReport) -> Float {
        let active = report.windows
            .filter { $0.referenceDBFS >= -45 }
            .map(\.reductionDb)
            .sorted()
        guard !active.isEmpty else { return 0 }
        return active[active.count / 2]
    }

    private func write(_ samples: [Float], _ name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try AudioMixer.saveWAV(
            samples: samples, sampleRate: AudioConstants.targetSampleRate, url: url,
        )
        return url
    }

    /// The characterization that gives the file path its right to exist: it has
    /// to be the same canceller, not a second one that drifts. Fails against an
    /// identity stub, and against a chunked implementation that resets the
    /// streaming context on a block boundary.
    func testFileToFileMatchesTheArrayFormSampleForSample() async throws {
        let model = try requireLocalVQEModel()
        let farEnd = EchoTestAudio.speechLike(seconds: 4, seed: 11)
        let micURL = try write(farEnd.map { $0 * 0.5 }, "mic.wav")
        let refURL = try write(farEnd, "ref.wav")
        let canceller = LocalVQECanceller(modelPath: model)

        // The array form is fed what the FILES contain, not the Float32 arrays
        // they were written from. The intermediates are 16-bit PCM, and the
        // canceller is a neural model: a quantisation step at the input does
        // not stay a quantisation step at the output. Comparing against the
        // unquantised arrays measured that difference and called it drift.
        let expected = try await canceller.cancelEcho(
            mic: AudioMixer.loadAudioFileAsFloat32(url: micURL),
            reference: AudioMixer.loadAudioFileAsFloat32(url: refURL),
        )
        let output = workDir.appendingPathComponent("out.wav")
        _ = try await canceller.cancelEcho(
            micURL: micURL, referenceURL: refURL, outputURL: output, referenceLead: 0,
        )
        let got = try AudioMixer.loadAudioFileAsFloat32(url: output)

        XCTAssertEqual(got.count, expected.count)
        let worst = zip(got, expected).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(
            worst, 2.0 / 32767.0,
            "same canceller on the same input, one output quantisation step apart",
        )
    }

    /// The seam's contract: a reference shorter than the microphone is silence
    /// past its end. A recording where the app track stopped early must still
    /// produce a full-length microphone track, or the transcript loses its tail.
    func testShortReferenceIsTreatedAsSilenceAndOutputKeepsMicLength() async throws {
        let model = try requireLocalVQEModel()
        let farEnd = EchoTestAudio.speechLike(seconds: 3, seed: 3)
        let mic = EchoTestAudio.speechLike(seconds: 3, seed: 4)
        let output = workDir.appendingPathComponent("out.wav")

        _ = try await LocalVQECanceller(modelPath: model).cancelEcho(
            micURL: write(mic, "mic.wav"),
            referenceURL: write(Array(farEnd.prefix(farEnd.count / 3)), "ref.wav"),
            outputURL: output, referenceLead: 0,
        )

        let got = try AudioMixer.loadAudioFileAsFloat32(url: output)
        XCTAssertEqual(got.count, mic.count)
    }

    /// The report is measurement, not a verdict: one entry per window, carrying
    /// the reference level beside the reduction. Which windows count is the
    /// self-check's business, and keeping the threshold out of here is what
    /// lets it be chosen from data without touching the canceller.
    func testTheReportCarriesOneWindowPerSecondWithTheReferenceLevel() async throws {
        let model = try requireLocalVQEModel()
        let farEnd = EchoTestAudio.speechLike(seconds: 5, seed: 5)
        let output = workDir.appendingPathComponent("out.wav")

        let report = try await LocalVQECanceller(modelPath: model).cancelEcho(
            micURL: write(farEnd.map { $0 * 0.5 }, "mic.wav"),
            referenceURL: write(farEnd, "ref.wav"),
            outputURL: output, referenceLead: 0,
        )

        XCTAssertEqual(report.windows.count, 5)
        // Echo only, so the canceller has everything to remove and nothing to
        // keep. A floor far below what a healthy model reaches, to pin the
        // plumbing rather than the model's quality.
        let median = report.windows.map(\.reductionDb).sorted()[report.windows.count / 2]
        XCTAssertGreaterThan(median, 6.0)
        XCTAssertGreaterThan(report.windows[0].referenceDBFS, -60)
    }

    /// A cancelled run must not leave the partial file behind. It sits beside
    /// the destination, and a later run that found it there would be working
    /// next to a stranger's leftovers.
    func testACancelledRunLeavesNoPartialFile() async throws {
        let model = try requireLocalVQEModel()
        let output = workDir.appendingPathComponent("out.wav")
        let mic = try write(EchoTestAudio.speechLike(seconds: 3, seed: 21), "mic.wav")
        let ref = try write(EchoTestAudio.speechLike(seconds: 3, seed: 22), "ref.wav")

        let task = Task {
            try await LocalVQECanceller(modelPath: model).cancelEcho(
                micURL: mic, referenceURL: ref, outputURL: output, referenceLead: 0,
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path + ".partial"),
            "the staging file has to go with the run that made it",
        )
    }

    /// The two capture files do not share sample 0. The recorder starts them
    /// independently and reports the delta as `micDelay`, and a Bluetooth
    /// device spinning up makes it large. Fed a reference that does not line
    /// up, the canceller is not weaker, it is looking at the wrong audio.
    ///
    /// Asserted on the reduction the report carries, not through the check
    /// that later judges it: what the seam owes is that lining the reference
    /// up changes what comes out, and a test that borrowed a downstream
    /// policy for the assertion would fail whenever that policy moved.
    func testTheReferenceLeadIsWhatMakesTheCancellationWork() async throws {
        let model = try requireLocalVQEModel()
        // Two seconds, which is half the fixture's speak/pause period, so the
        // unaligned reference is loud exactly where the echo is not. A smaller
        // offset proves less than it looks: the model's own front-end searches
        // for the echo path, and with a periodic fixture a shift that keeps
        // most of the activity overlapping is one it can still work through.
        let leadSeconds = 2.0
        let leadSamples = Int(leadSeconds * Double(AudioConstants.targetSampleRate))
        // With pauses, because the self-check is a difference and a far end
        // that never stops leaves nothing to compare against. A real call has
        // gaps; the fixture generator does not, so they are cut in here.
        var farEnd = EchoTestAudio.speechLike(seconds: 30, seed: 41)
        let rate = AudioConstants.targetSampleRate
        for block in 0 ..< 15 where block.isMultiple(of: 2) {
            for index in (block * 2 * rate) ..< min((block * 2 + 2) * rate, farEnd.count) {
                farEnd[index] = 0
            }
        }
        // The microphone file starts late, so its first sample belongs with
        // the reference two seconds in. Exactly what a positive micDelay is.
        let mic = Array(EchoTestAudio.bleed(farEnd, delayMs: 15, gain: 0.5).dropFirst(leadSamples))
        let micURL = try write(mic, "mic.wav")
        let refURL = try write(farEnd, "ref.wav")
        let canceller = LocalVQECanceller(modelPath: model)

        let aligned = try await canceller.cancelEcho(
            micURL: micURL, referenceURL: refURL,
            outputURL: workDir.appendingPathComponent("aligned.wav"),
            referenceLead: leadSeconds,
        )
        let unaligned = try await canceller.cancelEcho(
            micURL: micURL, referenceURL: refURL,
            outputURL: workDir.appendingPathComponent("unaligned.wav"),
            referenceLead: 0,
        )

        XCTAssertGreaterThan(
            activeMedianReduction(aligned), 15,
            "with the reference lined up the echo has to go",
        )
        XCTAssertLessThan(
            activeMedianReduction(unaligned), 3,
            "without it the canceller is looking at the wrong audio",
        )
    }

    /// The other sign, which `micDelay` produces just as readily: the
    /// reference starts late, so its head is the silence the microphone heard
    /// nothing of and has to be padded rather than sought.
    ///
    /// Worth its own test because the padding is where the arithmetic can go
    /// wrong without looking wrong: a first block that pads correctly and then
    /// consumes a full block from the file leaves every later block early by
    /// exactly the amount the padding was meant to correct, and the head of
    /// the recording sounds right while the rest is misaligned.
    func testANegativeLeadPadsTheReferenceWithoutLosingWhatFollows() async throws {
        let model = try requireLocalVQEModel()
        let lagSeconds = 2.0
        let lagSamples = Int(lagSeconds * Double(AudioConstants.targetSampleRate))
        var farEnd = EchoTestAudio.speechLike(seconds: 30, seed: 43)
        let rate = AudioConstants.targetSampleRate
        for block in 0 ..< 15 where block.isMultiple(of: 2) {
            for index in (block * 2 * rate) ..< min((block * 2 + 2) * rate, farEnd.count) {
                farEnd[index] = 0
            }
        }
        // The reference file is missing its head, so the microphone's sample 0
        // belongs with reference sample -lag. A negative lead.
        let micURL = try write(EchoTestAudio.bleed(farEnd, delayMs: 15, gain: 0.5), "mic.wav")
        let refURL = try write(Array(farEnd.dropFirst(lagSamples)), "ref.wav")
        let canceller = LocalVQECanceller(modelPath: model)

        let aligned = try await canceller.cancelEcho(
            micURL: micURL, referenceURL: refURL,
            outputURL: workDir.appendingPathComponent("aligned.wav"),
            referenceLead: -lagSeconds,
        )
        let unaligned = try await canceller.cancelEcho(
            micURL: micURL, referenceURL: refURL,
            outputURL: workDir.appendingPathComponent("unaligned.wav"),
            referenceLead: 0,
        )

        XCTAssertGreaterThan(activeMedianReduction(aligned), 15)
        XCTAssertLessThan(activeMedianReduction(unaligned), 3)
    }

    func testAnAbsentModelFailsBeforeWritingAnOutputFile() async throws {
        let output = workDir.appendingPathComponent("out.wav")
        do {
            _ = try await LocalVQECanceller(modelPath: "/nonexistent/model.gguf").cancelEcho(
                micURL: write(EchoTestAudio.speechLike(seconds: 1, seed: 1), "mic.wav"),
                referenceURL: write(EchoTestAudio.speechLike(seconds: 1, seed: 2), "ref.wav"),
                outputURL: output, referenceLead: 0,
            )
            XCTFail("expected modelLoadFailed")
        } catch EchoCancellationError.modelLoadFailed {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: output.path),
                "a half-written output would be adopted by the caller as a cancelled track",
            )
        }
    }
}
