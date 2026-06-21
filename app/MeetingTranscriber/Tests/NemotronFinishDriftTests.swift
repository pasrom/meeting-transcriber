import AudioTapLib
import FluidAudio
@testable import MeetingTranscriber
import XCTest

/// Empirical resolution of a code-review concern: the production session
/// finalizes each utterance with `manager.finish()` and KEEPS feeding the same
/// manager (resetting only on `flush()`). A reviewer flagged that `finish()`
/// pads + decodes the tail (advancing the encoder cache) and clears only the
/// token accumulation (not the decoder/encoder state), so cross-utterance state
/// could carry over → progressive drift after the first `speechEnd`.
///
/// This drives the REAL Nemotron model two ways on the same multi-utterance
/// German fixture and compares the transcripts:
///   * PROD  — the actual `NemotronStreamingCaptionSession` (real manager + real
///     FluidVAD), `finish()` per VAD boundary, joined finals.
///   * BASE  — feed all audio, `finish()` ONCE (the validated PoC pattern).
/// If PROD ≈ BASE the finalize-and-continue pattern is sound; if PROD degrades
/// in the later utterances, it is not.
///
/// Gated (loads the ~0.6 GB model + runs inference):
///   RUN_NEMOTRON_DRIFT=1 swift test --filter NemotronFinishDriftTests
final class NemotronFinishDriftTests: XCTestCase {
    func testFinishPerUtteranceMatchesFinishOnce() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_NEMOTRON_DRIFT"] == "1",
            "gated: set RUN_NEMOTRON_DRIFT=1 (loads the real model)",
        )

        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: fixtureURL("two_speakers_de.wav"))
        XCTAssertEqual(sampleRate, 16000, "fixture must be 16 kHz")
        print("[drift] fixture: \(samples.count) samples (\(Double(samples.count) / 16000.0)s)")

        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(languageCode: "de", chunkMs: 2240)
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: dir)

        // --- PROD: production session, finish()-per-VAD-boundary ---
        let recorder = FinalRecorder()
        let sink: StreamingTranscriber.EventSink = { event in
            if case let .finalized(text, _) = event { recorder.add(text) }
        }
        let session = NemotronStreamingCaptionSession(
            manager: NemotronAsrManager(shared: shared, languageCode: "de"),
            detector: FluidVADBoundaryDetector(vad: FluidVAD(threshold: 0.5)),
            channelLabel: "drift",
            onEvent: sink,
        )
        try await session.prepare()
        var index = 0
        while index < samples.count {
            let end = min(index + 4096, samples.count)
            await session.ingest(LiveAudioBuffer(
                samples: Array(samples[index ..< end]), channelCount: 1, sampleRate: 16000, hostTime: 0,
            ))
            index = end
        }
        await session.flush()
        let finals = recorder.all()
        let prodTranscript = finals.joined(separator: " ")

        // --- BASE: feed all, finish() once ---
        let base = StreamingNemotronMultilingualAsrManager()
        try await base.loadFromShared(shared)
        await base.setLanguage("de")
        _ = try await base.process(samples: samples)
        let baseTranscript = try await base.finish()

        let wer = Self.wordErrorRate(hypothesis: prodTranscript, reference: baseTranscript)

        print("[drift] PROD finalized utterances (\(finals.count)):")
        for (i, f) in finals.enumerated() {
            print("[drift]   [\(i)] \(f)")
        }
        print("[drift] PROD (finish-per-utterance, \(prodTranscript.split(separator: " ").count) words):\n\(prodTranscript)")
        print("[drift] BASE (finish-once, \(baseTranscript.split(separator: " ").count) words):\n\(baseTranscript)")
        print(String(format: "[drift] WER(prod vs base) = %.1f%%", wer * 100))

        // Regression guard: finalize-and-continue must track the one-shot decode.
        // Measured ~1.1% on the 2-speaker fixture; the generous 15% bound catches
        // real cross-utterance drift (which would be 50%+) without flaking on
        // benign boundary-segmentation differences.
        XCTAssertGreaterThanOrEqual(finals.count, 5, "expected several finalized utterances")
        XCTAssertLessThan(wer, 0.15, "finish-per-utterance drifted from finish-once (WER \(wer))")
    }

    /// Word-level Levenshtein WER, hypothesis vs reference (lowercased, punctuation-insensitive split).
    private static func wordErrorRate(hypothesis: String, reference: String) -> Double {
        let normalize: (String) -> [String] = { text in
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let hyp = normalize(hypothesis)
        let ref = normalize(reference)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var prev = Array(0 ... hyp.count)
        var curr = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1 ... ref.count {
            curr[0] = i
            for j in 1 ... hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }
}

/// Thread-safe sink for the session's `@Sendable` finalized-caption callback.
private final class FinalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ text: String) {
        lock.lock()
        items.append(text)
        lock.unlock()
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
