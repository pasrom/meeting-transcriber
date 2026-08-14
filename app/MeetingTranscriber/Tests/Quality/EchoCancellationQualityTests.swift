@testable import MeetingTranscriber
import XCTest

/// Does removing the echo damage the local speaker's own words?
///
/// This is the measurement an external proposal for the same problem was
/// rejected on — it deleted roughly a third of the local speaker's words — so
/// this implementation has to face it too. The always-on guard
/// (`EchoCancellerTests.testUnrelatedReferenceLeavesTheMicrophoneAlone`) only
/// checks that half the *energy* survives, which is far too loose to notice a
/// word-level collapse.
///
/// Assertions are on **deltas measured inside one run**: same machine, same
/// engine instance, same audio. A single absolute WER on a synthesised mix would
/// encode one machine's numbers.
@MainActor
final class EchoCancellationQualityTests: XCTestCase {
    private var modelVariant: String {
        ProcessInfo.processInfo.environment["WHISPERKIT_MODEL"]
            ?? "openai_whisper-large-v3-v20240930_turbo"
    }

    /// Long enough that a single wrong word moves WER by 0.003 rather than
    /// 0.036: the German fixtures are too short to tell a real regression from
    /// one flipped token.
    private let localFixture = "four_speakers_en_ami"
    private let remoteFixture = "three_speakers_de"

    /// Measures solo / bled / cleaned and reports all three. Bounds come from
    /// what this prints, not from a guess — see the plan in
    /// `docs/plans/.local/open/2026-08-14-echo-quality-gate-plan.md`.
    func test_cancellation_preservesLocalSpeech_wer() async throws {
        try skipUnlessQualityRun()
        guard let modelPath = await EchoCancellerModel.ensureAvailable() else {
            throw XCTSkip("LocalVQE weights unavailable")
        }
        let canceller = try XCTUnwrap(EchoCanceller(modelPath: modelPath))

        let truth = try GroundTruth.load(named: localFixture)
        let local = try await loadFixtureAs16kMono(truth.audioURL)
        let remoteTruth = try GroundTruth.load(named: remoteFixture)
        let remote = try await loadFixtureAs16kMono(remoteTruth.audioURL)

        let (mic, reference) = EchoQualityMix.doubleTalk(local: local, remote: remote)
        let cleaned = try canceller.process(mic: mic, reference: reference)

        let engine = WhisperKitEngine()
        engine.modelVariant = modelVariant
        engine.language = "en"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "WhisperKit model failed to load")

        let solo = try await transcribe(local, engine: engine, label: "solo")
        let bled = try await transcribe(mic, engine: engine, label: "bled")
        let clean = try await transcribe(cleaned, engine: engine, label: "cleaned")

        for (label, hyp) in [("solo", solo), ("bled", bled), ("cleaned", clean)] {
            let b = WERCalculator.werBreakdown(reference: truth.text, hypothesis: hyp)
            let del = Double(b.deletions) / Double(max(b.referenceLength, 1))
            let ins = Double(b.insertions) / Double(max(b.referenceLength, 1))
            print(String(
                format: "ECHOQUALITY %@ wer=%.4f del=%.4f ins=%.4f sub=%d ref=%d",
                label, b.wer, del, ins, b.substitutions, b.referenceLength,
            ))
        }
    }

    private func transcribe(
        _ samples: [Float], engine: WhisperKitEngine, label: String,
    ) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echoquality-\(label)-\(UUID().uuidString).wav")
        try AudioMixer.saveWAV(samples: samples, sampleRate: EchoQualityMix.rate, url: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await engine.transcribe(audioPath: url)
    }
}
