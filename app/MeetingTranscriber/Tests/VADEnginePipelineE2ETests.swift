@testable import MeetingTranscriber
import XCTest

/// End-to-end coverage for the chain `FluidVAD → engine → VadSegmentMap.remap`.
/// Both halves are unit-tested in isolation (`FluidVADTests`, `VadSegmentMap`
/// remap math), but the integration is the historical hotspot — silent or
/// off-by-one drift in `extractSpeechSamples` or `toOriginalTime` causes the
/// final protocol to attribute speech to the wrong wall-clock minute.
///
/// Strategy: feed a fixture with an engineered 5 s silence in [8s, 13s] of
/// the original timeline. After VAD-trim + transcribe + remap, no segment
/// timestamp may fall inside that range; segments after t=13s must remain
/// after t=13s. Gated like the rest of `*E2ETests` — needs the WhisperKit
/// model.
@MainActor
final class VADEnginePipelineE2ETests: XCTestCase {
    private static let fixtureName = "two_speakers_de_with_silence.wav"
    // Must match `scripts/generate_test_audio_with_silence.sh`: split source at
    // 8 s + insert 5 s silence → silence range [8 s, 13 s] on the original
    // timeline. If the script changes, regenerate the fixture and update both.
    private static let silenceStart: TimeInterval = 8.0
    private static let silenceEnd: TimeInterval = 13.0

    func test_vadTrimAndRemap_keepsTranscriptOutOfSilence() async throws {
        try skipIfCIWithoutE2EOptIn("requires WhisperKit model download")
        let fixture = fixtureURL(Self.fixtureName)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Fixture missing: \(fixture.path) — run scripts/generate_test_audio_with_silence.sh",
        )

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)

        let vad = FluidVAD(threshold: 0.5)
        let (samples, _) = try await AudioMixer.loadAudioAsFloat32(url: fixture)
        let map = try await vad.detectSpeech(samples: samples)
        XCTAssertFalse(map.segments.isEmpty, "VAD should detect speech around the engineered silence")

        // Extract speech-only samples and write them to a temp file so the engine
        // sees the same trimmed input that PipelineQueue would feed it.
        let trimmedSamples = map.extractSpeechSamples(from: samples)
        XCTAssertGreaterThan(trimmedSamples.count, 0)
        let tmpDir = try makeTempDirectory(prefix: "vad_pipeline")
        let trimmedPath = tmpDir.appendingPathComponent("vad_trimmed.wav")
        try AudioMixer.saveWAV(
            samples: trimmedSamples,
            sampleRate: AudioConstants.targetSampleRate,
            url: trimmedPath,
        )

        let trimmedSegments = try await engine.transcribeSegments(audioPath: trimmedPath)
        XCTAssertFalse(trimmedSegments.isEmpty, "engine should produce transcript on trimmed audio")
        let remapped = map.remapTimestamps(trimmedSegments)

        // Core invariant: the engineered silence must not contain any segment
        // start. We allow segments to *cross* the boundary at the very edges
        // (VAD chunk size ≈ 256 ms causes some boundary slop), but no segment
        // should originate strictly inside the silence range. Slop = 0.3 s
        // gives ~1 chunk margin on each side without masking real drift bugs.
        let edgeSlop: TimeInterval = 0.3
        let innerStart = Self.silenceStart + edgeSlop
        let innerEnd = Self.silenceEnd - edgeSlop
        for seg in remapped {
            XCTAssertFalse(
                seg.start > innerStart && seg.start < innerEnd,
                "segment start \(seg.start) lies inside engineered silence "
                    + "[\(innerStart), \(innerEnd)]: \(seg.text)",
            )
        }

        // At least one segment must originate after the silence so we know the
        // post-silence audio survived the trim+remap (catches a regression that
        // accidentally drops the back half).
        XCTAssertTrue(
            remapped.contains { $0.start >= Self.silenceEnd - edgeSlop },
            "no transcript segment landed after silenceEnd — back half was dropped or "
                + "remap collapsed everything: \(remapped.map(\.start))",
        )

        // The remapped timeline must respect the fixture's wall-clock duration:
        // every segment end must be ≤ originalDuration. A drift bug that returned
        // trimmed-relative timestamps would produce ends well past the original.
        let originalDuration = map.originalDuration
        for seg in remapped {
            XCTAssertLessThanOrEqual(
                seg.end,
                originalDuration + edgeSlop,
                "segment end \(seg.end) exceeds original duration \(originalDuration) — "
                    + "remap likely returned trimmed-timeline timestamps",
            )
        }
    }
}
