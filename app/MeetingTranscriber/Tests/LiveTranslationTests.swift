import AudioTapLib
@testable import MeetingTranscriber
import XCTest

@MainActor
final class LiveTranslationTests: XCTestCase {
    func testTranslationUsesWhisperForPartialsAndFinalsOnBothChannels() async throws {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.outputMode = .translateToEnglish
        let client = TranslationDecodingClient()
        engine.installDecodingClientForTesting(client)
        let session = try XCTUnwrap(engine.session(for: engine.transcriptionConfiguration) as? any StreamingTranscribingEngine)
        let captions = LiveCaptionsState()
        let controller = LiveTranscriptionController(
            engine: session, vad: FluidVAD(threshold: 0.5), captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(), engineLanguage: "en",
            eouSessionFactory: {
                XCTFail("Translation must not load the English-only streaming backend")
                return MockEouManager()
            },
            nemotronPipelineFactory: { _, _, _ in
                XCTFail("Translation must not load Nemotron")
                throw TranscriptionError.streamingNotSupported
            },
        )
        await controller.prepare()
        XCTAssertEqual(captions.activeBackend, "Whisper · Translate to English")
        let (samples, _) = try await AudioMixer.loadAudioAsFloat32(url: fixtureURL())
        // Enough real speech for VAD to emit a partial and a final; ASR is the
        // capturing decoder, so this is caption wiring, not a translation score.
        let clip = Array(samples.prefix(16000 * 4))
        let buffer = LiveAudioBuffer(samples: clip, channelCount: 1, sampleRate: 16000, hostTime: 0)
        controller.micSink(buffer)
        controller.appSink(buffer)
        await controller.flush()
        // Event sinks hop to MainActor. Yield until both finalized events land.
        for _ in 0 ..< 100 {
            if captions.recentFinals.count == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(Set(captions.recentFinals.map(\.channel)), [.mic, .app])
        XCTAssertTrue(captions.recentFinals.allSatisfy { $0.text == "We will ship on Friday." })
        XCTAssertGreaterThan(client.sampleOptions.count, 2, "Both partial and final calls must reach Whisper")
        XCTAssertTrue(client.sampleOptions.allSatisfy { $0.task == .translate })
    }
}
