import AudioTapLib
import FluidAudio
import Foundation
@testable import MeetingTranscriber
import XCTest

/// Real-model end-to-end proof for the English low-latency streaming-captions
/// path. Drives a REAL `StreamingEouAsrManager(chunkSize: .ms320)` (the same
/// Parakeet EOU 120M streaming model the production English-streaming backend
/// builds, see `LiveTranscriptionController.makeDefaultEouManager`) through the
/// production `EouStreamingCaptionSession` actor, feeding the committed English
/// fixture in realtime-SIZED chunks back-to-back.
///
/// Complements the mock-based `EouStreamingCaptionSessionTests` (callback
/// timing, prefix-monotonic partials, flush-final, audio slicing) by proving
/// the same session contract against the actual manager: partials really
/// arrive, prefix-stripping really recovers non-repeating finals, and the flush
/// path really commits the trailing transcript.
///
/// Gating mirrors the heavy-model E2Es (`ParakeetEngineE2ETests` et al.) via
/// the shared E2E gate: it runs in regular `swift test` (so it skips cleanly
/// when CI hasn't opted in via `E2E_ENABLED=1`) and skips if the fixture is
/// missing. The EOU 320ms model is
/// preloaded by `ModelPreloadTests.testPreloadEouStreaming`, so the additional
/// wall-clock here is just feeding the ~15 s fixture through a warm model
/// (seconds locally).
final class EouStreamingE2ETests: XCTestCase {
    /// Content words from `scripts/generate_test_audio_en.sh`. The transcript is
    /// lowercase without punctuation, so recall is computed case-insensitively
    /// over this set. Tolerant to small ASR misses (threshold below 1.0).
    private static let expectedWords = [
        "good", "morning", "everyone", "welcome", "weekly", "project", "meeting",
        "let", "us", "review", "status", "new", "feature",
        "thanks", "development", "going", "well", "we", "are", "schedule",
        "all", "tests", "passing", "release", "ready",
    ]

    /// Thread-safe event sink shared between the `@Sendable` `onEvent` closure
    /// (fired on the manager's executor) and the test body. `EouStreamingCaptionSession`
    /// emits `StreamingTranscriber.Event` values.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [StreamingTranscriber.Event] = []

        func append(_ event: StreamingTranscriber.Event) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }

        func snapshot() -> [StreamingTranscriber.Event] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    func testEnglishStreamingProducesFinalisedCaptionsWithRealModel() async throws {
        try skipIfCIWithoutE2EOptIn("real EOU streaming model is heavy")

        let fixture = fixtureURL("two_speakers_en.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "English test fixture not found at \(fixture.path)",
        )

        let samples = try await loadFixtureAs16kMono(fixture)
        XCTAssertFalse(samples.isEmpty, "fixture decoded to no samples")

        // Build the production session over a REAL manager at the production
        // chunk size + debounce.
        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
        let collector = EventCollector()
        let session = EouStreamingCaptionSession(asr: manager, channelLabel: "e2e") { event in
            collector.append(event)
        }
        try await session.prepare()

        await drive(samples, through: session)
        let events = collector.snapshot()

        // (a) Streaming liveness: the real manager fired at least one partial.
        let partials = events.compactMap { event -> String? in
            if case let .partial(text) = event { return text }
            return nil
        }
        XCTAssertFalse(
            partials.isEmpty,
            "expected at least one .partial event from the real streaming manager",
        )

        // Collect every finalized event (text + audio).
        let finals: [(text: String, audio: [Float])] = events.compactMap { event in
            if case let .finalized(text, audio) = event { return (text, audio) }
            return nil
        }
        XCTAssertFalse(finals.isEmpty, "expected at least one finalized event after flush")

        // (b) Word recall against the known script. The threshold is a
        // catastrophic-breakage detector, not a quality gate (the WER lane in
        // quality-and-safety.yml owns quality): 0.72 == 18 of 25 words, which
        // leaves headroom for a colder CI runner losing a word or two at pause
        // boundaries (a warm local run scores ~0.88) while still failing hard
        // if the streaming path stops producing real text.
        let transcript = finals.map(\.text).joined(separator: " ")
        let recall = wordRecall(transcript: transcript, expected: Self.expectedWords)
        XCTAssertGreaterThanOrEqual(
            recall,
            0.72,
            "word recall too low (\(recall)) — transcript was: \(transcript.lowercased())",
        )

        assertAudioPlausible(finals, fixtureSampleCount: samples.count)
        assertNoVerbatimRepeats(finals)

        print("[EouStreamingE2E] recall=\(recall) finals=\(finals.count) partials=\(partials.count)")
        print("[EouStreamingE2E] transcript: \(transcript.lowercased())")
    }

    // MARK: - Helpers

    /// Feed the fixture in realtime-SIZED chunks (320 ms == 5120 samples at
    /// 16 kHz, matching the manager's chunk granularity) back-to-back, then
    /// flush. No real sleeping — the session actor serializes ingest internally.
    private func drive(_ samples: [Float], through session: EouStreamingCaptionSession) async {
        let chunkFrames = 5120 // 320 ms at 16 kHz
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkFrames, samples.count)
            // hostTime is irrelevant here: the session derives its ms timeline
            // from the ingested sample count, never from buffer host times.
            let buffer = LiveAudioBuffer(
                samples: Array(samples[offset ..< end]),
                channelCount: 1,
                sampleRate: 16000,
                hostTime: 0,
            )
            await session.ingest(buffer)
            offset = end
        }
        await session.flush()
    }

    /// (c) Every finalized event carries plausible audio: non-empty and no
    /// longer than the whole fixture.
    private func assertAudioPlausible(
        _ finals: [(text: String, audio: [Float])],
        fixtureSampleCount: Int,
    ) {
        for (index, entry) in finals.enumerated() {
            XCTAssertFalse(
                entry.audio.isEmpty,
                "finalized event \(index) carried empty audio (text: \(entry.text))",
            )
            XCTAssertLessThanOrEqual(
                entry.audio.count,
                fixtureSampleCount,
                "finalized event \(index) audio (\(entry.audio.count)) exceeds fixture (\(fixtureSampleCount))",
            )
        }
    }

    /// (d) Prefix-stripping works against the real manager: no two finals repeat
    /// the same non-empty text verbatim (the manager's accumulated transcript
    /// grows across utterances; the session must strip it).
    private func assertNoVerbatimRepeats(_ finals: [(text: String, audio: [Float])]) {
        let finalTexts = finals.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(
            Set(finalTexts).count,
            finalTexts.count,
            "finalized texts repeated verbatim — prefix-stripping regressed: \(finalTexts)",
        )
    }
}
