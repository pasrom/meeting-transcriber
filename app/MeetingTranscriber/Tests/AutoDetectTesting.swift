import AudioTapLib
@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import os
import XCTest

/// Shared helpers and fakes for the auto-detect caption tests; model and VAD inference are replaced.
@MainActor
protocol AutoDetectTesting {}

extension AutoDetectTesting {
    func buffer(_ marker: Float) -> LiveAudioBuffer {
        LiveAudioBuffer(samples: [Float](repeating: marker, count: 4096), channelCount: 1, sampleRate: 16000, hostTime: 0)
    }

    /// Sends one window, which must resolve to "still detecting" (one English window).
    func passFirstEnglishWindow(
        _ harness: AutoDetectHarness, _ controller: LiveTranscriptionController, detections: Int = 1,
    ) async {
        harness.sendFourSeconds(to: controller)
        let detected = await eventually { harness.engine.detectedSamples.count == detections }
        XCTAssertTrue(detected)
        await settleLanguageSwitch(controller)
        XCTAssertTrue(harness.captions.isDetectingLanguage, "test premise: one window does not decide")
    }

    /// Waits for the language switch for up to 5 s, so a decision parked on a gate fails instead of hanging.
    func settleLanguageSwitch(
        _ controller: LiveTranscriptionController, file: StaticString = #filePath, line: UInt = #line,
    ) async {
        let done = await finishes { await controller.waitForLanguageSwitch() }
        XCTAssertTrue(done, "the language switch did not finish within 5 s", file: file, line: line)
    }

    /// Whether `work` finished within 5 s, so a call parked on a gate fails instead of hanging.
    func finishes(_ work: @escaping @MainActor () async -> Void) async -> Bool {
        let finished = OSAllocatedUnfairLock(initialState: false)
        Task {
            await work()
            finished.withLock { $0 = true }
        }
        return await eventually { finished.withLock { $0 } }
    }

    func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

@MainActor
final class AutoDetectHarness {
    let captions = LiveCaptionsState()
    let engine = ProbeEngine()
    let retranscription = RetranscriptionProbe()
    var eouManagers: [ProbeEouManager] = []
    let confidentEnglish = Array(repeating: CaptionLanguageDetection(language: "en", probability: 0.95), count: 2)
    var eouLoadGate: ProbeGate?
    var eouFailureIndex: Int?
    var speechDetector: CaptionLanguageProbe.SpeechDetector = \.self
    var sinks: [LiveCaptionChannel: StreamingTranscriber.EventSink] = [:]

    func controller() -> LiveTranscriptionController {
        let factory: LiveTranscriptionController.ReTranscribePipelineFactory = { channel, transcribe, sink in
            self.sinks[channel] = sink
            return self.retranscription.make(channel: channel, transcribe: transcribe)
        }
        let eouFactory: LiveTranscriptionController.EouSessionFactory = {
            let manager = ProbeEouManager(
                gate: self.eouLoadGate, shouldFailLoad: self.eouManagers.count == self.eouFailureIndex,
            )
            self.eouManagers.append(manager)
            return manager
        }
        return LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            eouSessionFactory: eouFactory,
            reTranscribePipelineFactory: factory,
            speechDetector: speechDetector,
        )
    }

    private func buffer(_ marker: Float) -> LiveAudioBuffer {
        LiveAudioBuffer(samples: [Float](repeating: marker, count: 4096), channelCount: 1, sampleRate: 16000, hostTime: 0)
    }

    func sendFourSeconds(
        to controller: LiveTranscriptionController, channel: LiveCaptionChannel = .mic, markerOffset: Float = 0,
    ) {
        // 16 FluidVAD-sized chunks: 65,536 detected speech samples.
        for index in 1 ... 16 {
            let marker = markerOffset + Float(index) / 100
            let sink = channel == .mic ? controller.micSink : controller.appSink
            sink(buffer(marker))
        }
    }
}

@MainActor
final class ProbeEngine: StreamingTranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1
    var transcriptionProgress: Double = 1
    var multilingualAfterLoad = true
    var supportsCaptionLanguageDetection: Bool {
        modelState != .loaded || multilingualAfterLoad
    }

    var results: [CaptionLanguageDetection?] = []
    var error: (any Error)?
    var gate: ProbeGate?
    var detectedSamples: [[Float]] = []
    var cancelledDuringDetection = false
    var transcribeCallCount = 0

    private(set) var loadCount = 0

    func loadModel() {
        loadCount += 1
        modelState = .loaded
    }

    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }

    func transcribeSamples(_: [Float]) -> String {
        transcribeCallCount += 1
        return ""
    }

    func detectLanguage(samples: [Float]) async throws -> CaptionLanguageDetection? {
        detectedSamples.append(samples)
        await gate?.park()
        cancelledDuringDetection = Task.isCancelled
        if let error { throw error }
        return results.isEmpty ? nil : results.removeFirst()
    }
}

@MainActor
final class RetranscriptionProbe {
    private(set) var mic = ProbePipeline()
    private(set) var app = ProbePipeline()
    private(set) var installCount = 0

    func make(
        channel: LiveCaptionChannel,
        transcribe: @escaping StreamingTranscriber.TranscribeFunction,
    ) -> any LiveCaptionPipeline {
        installCount += 1
        let pipeline = ProbePipeline(transcribe: transcribe)
        if channel == .mic { mic = pipeline } else { app = pipeline }
        return pipeline
    }
}

actor ProbePipeline: LiveCaptionPipeline {
    private(set) var samples: [Float] = []
    private(set) var resetCount = 0
    private let transcribe: StreamingTranscriber.TranscribeFunction

    init(transcribe: @escaping StreamingTranscriber.TranscribeFunction = { _ in "" }) {
        self.transcribe = transcribe
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) async {
        if let first = buffer.samples.first { samples.append(first) }
        _ = try? await transcribe(buffer.samples)
    }

    func reset() {
        resetCount += 1
    }

    func flush() {}
}

actor ProbeGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func park() async {
        entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitUntilEntered() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

struct ProbeEouLoadFailure: Error {}

actor ProbeEouManager: EouStreamingAsrManaging {
    let gate: ProbeGate?
    let shouldFailLoad: Bool
    private(set) var samples: [Float] = []
    private(set) var loadCount = 0

    init(gate: ProbeGate?, shouldFailLoad: Bool) {
        self.gate = gate
        self.shouldFailLoad = shouldFailLoad
    }

    func loadModels() async throws {
        loadCount += 1
        await gate?.park()
        if shouldFailLoad { throw ProbeEouLoadFailure() }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func processBufferedAudio() {}
    func finish() -> String {
        ""
    }

    func reset() {}
    func setPartialCallback(_: @Sendable (String) -> Void) {}
    func setEouCallback(_: @Sendable (String) -> Void) {}
    func getEouTimestampsMs() -> [Int] {
        []
    }
}

final class ChunkCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    var count: Int {
        value.withLock { $0 }
    }

    func increment() {
        value.withLock { $0 += 1 }
    }
}
