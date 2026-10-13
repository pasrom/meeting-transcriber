import Foundation
@testable import MeetingTranscriber
import WhisperKit
import XCTest

@MainActor
final class TranslationPipelineTests: XCTestCase {
    func testEnqueueCapturesConfigurationAndSnapshotRoundTripPreservesIt() throws {
        let dir = try makeTempDirectory(prefix: "translation-snapshot")
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.outputMode = .translateToEnglish
        let queue = makeQueue(engine: engine, dir: dir)
        var job = makeJob(audio: dir.appendingPathComponent("audio.wav"))
        queue.stampTranscriptionConfiguration(on: &job)
        engine.outputMode = .original
        engine.language = "en"
        queue.stampTranscriptionConfiguration(on: &job)
        XCTAssertEqual(job.transcriptionConfiguration?.whisper?.outputMode, .translateToEnglish)
        XCTAssertNil(job.transcriptionConfiguration?.whisper?.language)
        try PipelineSnapshot.save([job], to: dir)
        let loaded = try XCTUnwrap(try PipelineSnapshot.load(from: dir)?.first)
        XCTAssertEqual(loaded.transcriptionConfiguration, job.transcriptionConfiguration)
        let session = try XCTUnwrap(queue.transcriptionEngine(for: loaded) as? WhisperTranscriptionSession)
        XCTAssertEqual(session.configuration, job.transcriptionConfiguration?.whisper)
    }

    func testLegacyJobWithoutConfigurationNeverAcquiresTranslationOnRestore() throws {
        let dir = try makeTempDirectory(prefix: "translation-legacy")
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.outputMode = .translateToEnglish
        let queue = makeQueue(engine: engine, dir: dir)
        let job = makeJob(audio: dir.appendingPathComponent("audio.wav"))
        let encoded = try JSONEncoder().encode(job)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "transcriptionConfiguration")
        let legacy = try JSONDecoder().decode(PipelineJob.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.transcriptionConfiguration)
        XCTAssertEqual(queue.transcriptionConfiguration(for: legacy).whisper?.outputMode, .original)
    }

    func testDualTrackTranslationReachesSavedTranscriptAndFullProtocolAppendix() async throws {
        let dir = try makeTempDirectory(prefix: "translation-pipeline")
        let audio = dir.appendingPathComponent("app.wav")
        let mic = dir.appendingPathComponent("mic.wav")
        let samples = [Float](repeating: 0.1, count: 32000)
        try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: audio)
        try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: mic)
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.outputMode = .translateToEnglish
        let client = TranslationDecodingClient()
        engine.installDecodingClientForTesting(client)
        client.onFileDecode = {
            engine.outputMode = .original
            engine.language = "en"
            engine.applyModelVariant("openai_whisper-large-v3-v20240930_turbo")
        }
        let generator = MockProtocolGen()
        let queue = makeQueue(engine: engine, dir: dir, generator: generator)
        // A paired import need not have a physical mix file.
        let job = PipelineJob(
            meetingTitle: "Bilingual meeting", appName: "Test", mixPath: nil,
            appPath: audio, micPath: mic, micDelay: 0,
        )
        queue.enqueue(job)
        await queue.awaitProcessing()
        let finished = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(finished.state, .done, finished.error ?? "")
        XCTAssertEqual(client.fileOptions.map(\.task), [.translate, .translate])
        XCTAssertTrue(client.fileOptions.allSatisfy { $0.language == nil && $0.detectLanguage })
        let transcript = try String(contentsOf: XCTUnwrap(finished.transcriptPath), encoding: .utf8)
        XCTAssertTrue(transcript.contains("[00:01] Remote: We will ship on Friday."))
        XCTAssertTrue(transcript.contains("[00:01] Me: We will ship on Friday."))
        XCTAssertEqual(generator.capturedTranscript, transcript)
        let markdown = try String(contentsOf: XCTUnwrap(finished.protocolPath), encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Full Transcript"))
        XCTAssertTrue(markdown.hasSuffix(transcript))
    }

    private func makeQueue(
        engine: WhisperKitEngine, dir: URL, generator: MockProtocolGen = MockProtocolGen(),
    ) -> PipelineQueue {
        PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { generator }, outputDir: dir, logDir: dir,
            echoDedupEnabled: false,
        )
    }

    private func makeJob(audio: URL) -> PipelineJob {
        PipelineJob(
            meetingTitle: "Bilingual meeting", appName: "Test", mixPath: audio,
            appPath: nil, micPath: nil, micDelay: 0,
        )
    }
}
