import AVFoundation
@testable import MeetingTranscriber
import XCTest

@MainActor
final class GigaAMEngineTests: XCTestCase {
    func testConcurrentLoadersShareOneDecoder() async {
        let engine = GigaAMEngine()
        let gate = MainActorGate()
        var loads = 0
        engine.installModelLoadForTesting {
            loads += 1
            await gate.wait()
            return { _ in [] }
        }

        let first = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        let second = Task {
            gate.open()
            await engine.loadModel()
        }
        await first.value
        await second.value

        XCTAssertEqual(loads, 1)
        XCTAssertEqual(engine.modelState, .loaded)
    }

    func testReleaseDiscardsInFlightDecoderAndNextLoadUsesNewGeneration() async throws {
        let engine = GigaAMEngine()
        let gate = MainActorGate()
        var loads = 0
        engine.installModelLoadForTesting {
            loads += 1
            let version = loads
            if version == 1 { await gate.wait() }
            return { _ in [.init(text: "▁Версия \(version).", firstFrame: 0, endFrame: 1)] }
        }

        let first = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        engine.releaseModel()
        let next = Task {
            gate.open()
            await engine.loadModel()
        }
        await first.value
        await next.value

        XCTAssertEqual(loads, 2)
        XCTAssertEqual(engine.modelState, .loaded)
        let text = try await engine.transcribeSamples([Float](repeating: 0, count: engine.minimumAudioFrames))
        XCTAssertEqual(text, "Версия 2.")
    }

    func testReleasedLoadDoesNotPublishFailure() async {
        let engine = GigaAMEngine()
        let gate = MainActorGate()
        engine.installModelLoadForTesting {
            await gate.wait()
            throw URLError(.cannotLoadFromNetwork)
        }

        let load = Task { await engine.loadModel() }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        engine.releaseModel()
        gate.open()
        await load.value

        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertNil(engine.loadFailureReason)
    }

    func testFileDecoderRewindsToQuietCutWithoutSkippingSamples() async throws {
        let engine = GigaAMEngine()
        let probe = WindowProbe()
        engine.installModelLoadForTesting { { await probe.decode($0) } }
        let limit = GigaAMModel.maxSamples
        var samples = [Float](repeating: 0.5, count: limit + 1000)
        samples.replaceSubrange((limit - 3200) ..< (limit - 1600), with: repeatElement(0, count: 1600))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: path) }
        try writeSamples(samples, to: path)

        let segments = try await engine.transcribeSegments(audioPath: path)
        let decoded = await probe.windows
        XCTAssertEqual(decoded.map(\.count), [limit - 2400, 3400])
        XCTAssertEqual(decoded.flatMap(\.self), samples)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(try XCTUnwrap(segments.last).start, Double(limit - 2400) / 16000, accuracy: 0.0001)
        XCTAssertEqual(engine.transcriptionProgress, 1)
    }

    func testRussianCaptionsFallBackToGigaAMWhenNemotronFails() async throws {
        let settings = try makeIsolatedSettings()
        settings.transcriptionEngine = .gigaAM
        let engine = GigaAMEngine()
        var loads = 0
        engine.installModelLoadForTesting {
            loads += 1
            return { _ in [] }
        }
        let captions = LiveCaptionsState()
        let failNemotron: LiveTranscriptionController.NemotronPipelineFactory = { _, _, _ in
            throw URLError(.cannotLoadFromNetwork)
        }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: settings.activeEngineLanguageOrNil,
            nemotronPipelineFactory: failNemotron,
        )

        await controller.prepare()

        XCTAssertEqual(loads, 1)
        XCTAssertEqual(captions.activeBackend, "Re-transcribe · RU")
    }

    func testFileDecoderResamplesToTheModelRate() async throws {
        let engine = GigaAMEngine()
        let probe = WindowProbe()
        engine.installModelLoadForTesting { { await probe.decode($0) } }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: path) }
        try writeSamples([Float](repeating: 0.5, count: 32000), to: path, sampleRate: 32000)

        let segments = try await engine.transcribeSegments(audioPath: path)
        let counts = await probe.windows.map(\.count)
        XCTAssertEqual(counts.count, 1)
        let frames = try XCTUnwrap(counts.first)
        // Allow for the converter's leading and trailing frames.
        XCTAssertEqual(Double(frames), 16000, accuracy: 320)
        XCTAssertEqual(segments.count, 1)
    }

    func testMissingAudioIsAFileFailure() async {
        let engine = GigaAMEngine()
        engine.installModelLoadForTesting { { _ in [] } }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")

        do {
            _ = try await engine.transcribeSegments(audioPath: path)
            XCTFail("Expected a missing audio file error")
        } catch {
            XCTAssertEqual(TranscriptionFailureScope.of(error), .file)
        }
    }

    private func writeSamples(_ samples: [Float], to url: URL, sampleRate: Double = 16000) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false,
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        let destination = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: source.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private actor WindowProbe {
        private(set) var windows: [[Float]] = []

        func decode(_ samples: [Float]) -> [GigaAMModel.Piece] {
            windows.append(samples)
            return [.init(text: "▁Тест.", firstFrame: 0, endFrame: 1)]
        }
    }
}
