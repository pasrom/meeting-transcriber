@testable import MeetingTranscriber
import XCTest

/// Exercises the real LocalVQE library, not a stub. These are cheap (a few
/// seconds of 16 kHz audio through a 2.8 MB model) and they are the only place
/// the C bridging is checked at all, so they run in the normal suite rather
/// than behind an E2E gate — but they need the model on disk, so each skips
/// when it is absent instead of failing a machine that has never fetched it.
final class EchoCancellerTests: XCTestCase {
    private let rate = EchoTestAudio.rate

    /// Goes through the production fetch path rather than a test fixture, so
    /// the download, the checksum gate and the cache are exercised too. First
    /// run on a machine pulls 2.8 MB; every run after that is a file read.
    /// Skips rather than fails when the model cannot be obtained, so an offline
    /// machine does not turn the suite red for a missing network.
    private func makeCanceller() async throws -> EchoCanceller {
        guard let path = await EchoCancellerModel.ensureAvailable() else {
            throw XCTSkip("LocalVQE weights unavailable (offline, or the pinned revision moved)")
        }
        return try XCTUnwrap(EchoCanceller(modelPath: path), "the verified model must load")
    }

    func testModelReportsTheSampleRateThePipelineFeedsIt() async throws {
        let canceller = try await makeCanceller()
        XCTAssertEqual(canceller.sampleRate, 16000, "the pipeline resamples to 16 kHz before this point")
    }

    /// Settles a contradiction between two sources rather than trusting either:
    /// LocalVQE's header states the output is sample-aligned to the input,
    /// while the build spike compared results shifted by one 256-sample hop.
    ///
    /// Measured: the raw output lags by exactly one hop, so the header is
    /// wrong and `EchoCanceller` compensates. This test pins the compensated
    /// result at zero, which also means a model update that made the header
    /// true would fail here rather than silently shift the audio the other way.
    ///
    /// Measured by cancelling a track that has nothing to cancel — a silent
    /// reference — and cross-correlating input against output.
    func testOutputIsSampleAlignedWithTheInput() async throws {
        let canceller = try await makeCanceller()
        let mic = EchoTestAudio.speechLike(seconds: 4, seed: 7)
        let silentReference = [Float](repeating: 0, count: mic.count)

        let out = try (canceller.process(mic: mic, reference: silentReference))
        XCTAssertEqual(out.count, mic.count, "the caller's timeline must survive")

        // Skip the first hop: the header documents it as a tapered ramp from
        // zero, which is a real amplitude difference and not a misalignment.
        let skip = 512
        var best = (lag: 0, score: -Double.infinity)
        for lag in -512 ... 512 {
            var dot = 0.0
            var i = skip
            while i < mic.count - 512 {
                let j = i + lag
                if j >= 0, j < out.count { dot += Double(mic[i]) * Double(out[j]) }
                i += 1
            }
            if dot > best.score { best = (lag, dot) }
        }
        XCTAssertEqual(
            best.lag, 0,
            "output peaked at lag \(best.lag); a non-zero lag would offset the cancelled mic track from the app track it is merged against",
        )
    }

    /// The property the whole feature rests on: with the app track as the
    /// reference, the bled-in copy is removed.
    ///
    /// Real recorded speech, not the synthetic generator. The generator's
    /// carrier is white noise, which is spectrally flat everywhere; real speech
    /// is sparse in time and frequency, and how much of a mask lands on the
    /// wrong signal depends entirely on that sparsity. Measuring suppression
    /// with flat noise answers a question nobody asked.
    func testBleedIsAttenuatedAgainstItsOwnReference() async throws {
        let canceller = try await makeCanceller()
        let far = try await loadFixtureAs16kMono(fixtureURL())
        let mic = EchoTestAudio.bleed(far, delayMs: 15, gain: 0.5)

        let out = try (canceller.process(mic: mic, reference: far))

        let reductionDB = 10 * log10(Self.energy(mic.dropFirst(512)) / max(Self.energy(out.dropFirst(512)), 1e-12))
        XCTAssertGreaterThan(
            reductionDB, 6.0,
            "pure bleed against its own reference should drop well over 6 dB, got \(String(format: "%.1f", reductionDB)) dB",
        )
    }

    /// The failure that would be worst in the field: eating the person at the
    /// machine. Two unrelated real recordings, so the microphone track has
    /// nothing in it the reference can explain — the canceller must leave it
    /// essentially alone.
    ///
    /// This is the test that decides whether the feature is safe to run
    /// automatically rather than behind a switch the user has to find.
    func testUnrelatedReferenceLeavesTheMicrophoneAlone() async throws {
        let canceller = try await makeCanceller()
        let mic = try await loadFixtureAs16kMono(fixtureURL("three_speakers_de.wav"))
        let unrelated = try await loadFixtureAs16kMono(fixtureURL())

        let out = try (canceller.process(mic: mic, reference: unrelated))

        let kept = Self.energy(out.dropFirst(512)) / max(Self.energy(mic.dropFirst(512)), 1e-12)
        XCTAssertGreaterThan(
            kept, 0.5,
            "an unrelated reference must not remove local speech; kept \(String(format: "%.2f", kept)) of the energy",
        )
    }

    /// The gap every other layer had: all of them run at `micDelay == 0`, where
    /// the reference alignment cannot matter. A microphone that started late is
    /// missing that opening stretch, so its copy of the app audio sits earlier
    /// in file-index terms; feeding the tracks unshifted puts the echo in the
    /// microphone BEFORE the reference that caused it, which no echo canceller
    /// can undo. It then removes nothing and still returns success — and that
    /// success lifts the speaker-database quarantine.
    func testLateStartingMicrophoneNeedsTheReferenceAligned() async throws {
        let canceller = try await makeCanceller()
        let far = try await loadFixtureAs16kMono(fixtureURL())
        let delay = 2.0
        let lateStart = Int(delay * Double(rate))
        // Everything the mic would have captured, minus the two seconds it was
        // not yet recording.
        let mic = Array(EchoTestAudio.bleed(far, delayMs: 15, gain: 0.5).dropFirst(lateStart))

        let aligned = PipelineQueue.alignReference(far, micDelay: delay, sampleRate: rate)
        let cleaned = try canceller.process(mic: mic, reference: aligned)
        let reduction = 10 * log10(Self.energy(mic.dropFirst(512)) / max(Self.energy(cleaned.dropFirst(512)), 1e-12))
        XCTAssertGreaterThan(
            reduction, 6.0,
            "with the reference shifted onto the microphone's timeline the bleed must go, got \(String(format: "%.1f", reduction)) dB",
        )
    }

    /// The control for the test above: unaligned, the same audio must NOT come
    /// out clean. Without this the aligned test could pass on a canceller that
    /// ignores its reference entirely.
    func testLateStartingMicrophoneIsNotCleanedWithoutAlignment() async throws {
        let canceller = try await makeCanceller()
        let far = try await loadFixtureAs16kMono(fixtureURL())
        let lateStart = Int(2.0 * Double(rate))
        let mic = Array(EchoTestAudio.bleed(far, delayMs: 15, gain: 0.5).dropFirst(lateStart))

        let cleaned = try canceller.process(mic: mic, reference: far)
        let reduction = 10 * log10(Self.energy(mic.dropFirst(512)) / max(Self.energy(cleaned.dropFirst(512)), 1e-12))
        XCTAssertLessThan(
            reduction, 6.0,
            "an unshifted reference cannot cancel a late-started microphone; a pass here would mean the aligned test proves nothing",
        )
    }

    private static func energy(_ x: some Collection<Float>) -> Double {
        x.reduce(0.0) { $0 + Double($1) * Double($1) }
    }
}
