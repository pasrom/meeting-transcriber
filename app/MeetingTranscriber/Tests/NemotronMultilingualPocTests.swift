import FluidAudio
import Foundation
@testable import MeetingTranscriber
import XCTest

/// Thread-safe holder for the latest partial transcript (the manager fires the
/// callback off its actor; the test reads it after `finish()`).
private final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
    var last: String { lock.lock(); defer { lock.unlock() }; return value }
}

/// THROWAWAY PoC harness (spike branch only, NOT shipped). Measures
/// FluidAudio's `StreamingNemotronMultilingualAsrManager` on a known German
/// fixture: transcript sanity, RTFx (throughput), and WER vs ground truth.
///
/// Gated by `RUN_NEMOTRON_POC=1` because the first run pulls the ~611 MB
/// `de-DE` / 2240 ms variant from HuggingFace. Reuses the existing quality
/// infra (`GroundTruth`, `WERCalculator`) so the WER is comparable to the
/// `WhisperKitQualityTests` / `ParakeetQualityTests` numbers on the same audio.
///
/// Run: `RUN_NEMOTRON_POC=1 swift test --filter NemotronMultilingualPoc`
final class NemotronMultilingualPocTests: XCTestCase {
    private struct PocClip: Decodable {
        let id: Int
        let text: String
        let audio: String
    }

    /// Real-audio quality read: feeds a manifest of real German speech clips
    /// (each with its exact transcript) through the manager and reports per-clip
    /// + average WER. The synthetic fixtures are out-of-distribution for ASR, so
    /// this is the valid quality signal. Manifest: JSON array of {id,text,audio}.
    func testNemotronMultilingualRealClips() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_NEMOTRON_POC"] == "1",
            "Set RUN_NEMOTRON_POC=1 to run the Nemotron multilingual PoC",
        )
        guard let manifestPath = ProcessInfo.processInfo.environment["NEMOTRON_POC_MANIFEST"] else {
            throw XCTSkip("Set NEMOTRON_POC_MANIFEST=/path/to/manifest.json")
        }
        let clips = try JSONDecoder().decode(
            [PocClip].self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath)),
        )

        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "de-DE", chunkMs: 2240,
        )
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: dir)
        await manager.setLanguage("de-DE")

        var wers: [Double] = []
        var totalAudio = 0.0
        var totalElapsed = 0.0
        for clip in clips {
            let (samples, sr) = try await AudioMixer.loadAudioAsFloat32(
                url: URL(fileURLWithPath: clip.audio),
            )
            let secs = Double(samples.count) / Double(sr)
            let peak = samples.map { Swift.abs($0) }.max() ?? 0
            let t0 = Date()
            _ = try await manager.process(samples: samples)
            let hyp = try await manager.finish()
            totalElapsed += Date().timeIntervalSince(t0)
            totalAudio += secs
            let wer = WERCalculator.wer(reference: clip.text, hypothesis: hyp)
            wers.append(wer)
            print("POC-CLIP \(clip.id) samples=\(samples.count) sr=\(sr) "
                + "secs=\(String(format: "%.1f", secs)) peak=\(String(format: "%.3f", peak)) "
                + "WER=\(String(format: "%.3f", wer))")
            print("  REF: \(clip.text)")
            print("  HYP: \(hyp)")
            await manager.reset()
        }

        let avg = wers.isEmpty ? 0 : wers.reduce(0, +) / Double(wers.count)
        let rtfx = totalElapsed > 0 ? totalAudio / totalElapsed : 0
        print("=== NEMOTRON-POC REAL n=\(wers.count) "
            + "avgWER=\(String(format: "%.4f", avg)) "
            + "RTFx=\(String(format: "%.1f", rtfx))x ===")

        XCTAssertFalse(wers.isEmpty, "no clips in manifest")
    }

    func testNemotronMultilingualGermanFixture() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_NEMOTRON_POC"] == "1",
            "Set RUN_NEMOTRON_POC=1 to run the Nemotron multilingual PoC",
        )

        let truth = try GroundTruth.load(named: "two_speakers_de")
        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: truth.audioURL)
        XCTAssertEqual(sampleRate, 16_000, "harness expects 16 kHz mono")
        let audioSeconds = Double(samples.count) / Double(sampleRate)

        // Download + load the German latin/2240 ms variant (de-DE routes to the
        // vocab-pruned `latin/` folder — smaller decoder, faster than `auto`).
        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "de-DE",
            chunkMs: 2240,
        )
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: dir)
        print("POC-MARK: models loaded OK")
        await manager.setLanguage("de-DE")
        let promptId = await manager.promptId()
        print("POC-MARK: promptId after setLanguage(de-DE) = \(promptId)")

        // Capture the latest partial (the manager emits the FULL running
        // transcript per chunk, not a delta) to compare against finish().
        let partials = PartialBox()
        await manager.setPartialCallback { partials.set($0) }

        // Feed the whole clip in one block, matching FluidAudio's reference
        // `NemotronMultilingualTranscribe` (60 s blocks → a 17 s file is one
        // call). The manager drains 2240 ms chunks internally.
        let started = Date()
        _ = try await manager.process(samples: samples)
        print("POC-MARK: process() returned OK")
        let hypothesis = try await manager.finish()
        let elapsed = Date().timeIntervalSince(started)
        let detected = await manager.detectedLanguage() ?? "(none)"
        let stats = await manager.lastDecodeStats()
        let expectedChunks = Int((audioSeconds * 1000 / 2240).rounded(.up))
        print("POC-MARK: detected=\(detected) tokenCount=\(stats.tokenCount) "
            + "processedChunks=\(stats.processedChunks) expectedChunks≈\(expectedChunks)")

        let wer = WERCalculator.wer(reference: truth.text, hypothesis: hypothesis)
        let rtfx = elapsed > 0 ? audioSeconds / elapsed : 0

        print("=== NEMOTRON-POC two_speakers_de ===")
        print(String(
            format: "audio=%.1fs elapsed=%.2fs RTFx=%.1fx WER=%.4f",
            audioSeconds, elapsed, rtfx, wer,
        ))
        print("REFERENCE:    \(truth.text)")
        print("FINISH:       \(hypothesis)")
        print("LAST-PARTIAL: \(partials.last)")
        print("=== /NEMOTRON-POC ===")

        // Sanity gates only — this is a measurement, not a behavioural spec.
        XCTAssertFalse(
            hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "empty transcript",
        )
        XCTAssertGreaterThan(rtfx, 1.0, "slower than real-time on this machine")
    }
}
