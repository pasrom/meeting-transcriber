import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Unit tests for `NemotronStreamingCaptionSession` — the VAD-driven German
/// streaming caption session. Both collaborators are injected as seams so the
/// finalization logic is exercised without loading the ~1.5 GB Nemotron models
/// or the Silero VAD: a scripted `UtteranceBoundaryDetecting` decides when
/// `speechStart`/`speechEnd` fire, and a `MockNemotronManager` models the real
/// manager's contract — `latestTranscript()` returns the in-progress partial,
/// and `finish()` returns the complete utterance text AND clears it (so the
/// next utterance starts fresh, as the real `finish()` clears its token
/// accumulation while keeping encoder state).
final class NemotronStreamingCaptionSessionTests: XCTestCase {
    /// 4096 non-silent samples = one VAD chunk at 16 kHz (~256 ms).
    private func chunkBuffer(value: Float = 0.1) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: [Float](repeating: value, count: 4096),
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 0,
        )
    }

    private func makeSession(
        manager: MockNemotronManager,
        detector: ScriptedBoundaryDetector,
        recorder: EventRecorder,
    ) -> NemotronStreamingCaptionSession {
        let sink: StreamingTranscriber.EventSink = { recorder.record($0) }
        return NemotronStreamingCaptionSession(
            manager: manager,
            detector: detector,
            channelLabel: "mic",
            onEvent: sink,
        )
    }

    private func finals(_ events: [StreamingTranscriber.Event]) -> [(text: String, audio: [Float])] {
        events.compactMap { event in
            if case let .finalized(text, audio) = event { return (text, audio) }
            return nil
        }
    }

    private func partials(_ events: [StreamingTranscriber.Event]) -> [String] {
        events.compactMap { event in
            if case let .partial(text) = event { return text }
            return nil
        }
    }

    /// A VAD `speechEnd` finalizes the in-progress utterance via `finish()`,
    /// emitting the complete transcript paired with the buffered speech audio
    /// (so the controller's event sink can derive a speaker embedding).
    func testSpeechEndFinalizesUtteranceWithSpeechAudio() async {
        let manager = MockNemotronManager()
        await manager.setFinish("hallo welt")
        let recorder = EventRecorder()
        // start + 3×none = 4 chunks of speech (16384 samples ≈ 1.02 s) clears
        // the 1 s noise minimum; the speechEnd chunk commits but isn't appended.
        let session = makeSession(
            manager: manager,
            detector: ScriptedBoundaryDetector(script: [.speechStart, nil, nil, nil, .speechEnd]),
            recorder: recorder,
        )

        for _ in 0 ..< 5 {
            await session.ingest(chunkBuffer())
        }

        let finalEvents = finals(recorder.events)
        XCTAssertEqual(finalEvents.count, 1, "exactly one final on speechEnd")
        XCTAssertEqual(finalEvents.first?.text, "hallo welt")
        XCTAssertEqual(finalEvents.first?.audio.count, 4 * 4096)
    }

    /// While speech is in progress (between start and end) the running partial
    /// transcript is emitted as partials, not finals.
    func testRunningTranscriptEmittedAsPartialDuringSpeech() async {
        let manager = MockNemotronManager()
        await manager.setPartial("guten")
        let recorder = EventRecorder()
        let session = makeSession(
            manager: manager,
            detector: ScriptedBoundaryDetector(script: [.speechStart, nil, nil]),
            recorder: recorder,
        )

        for _ in 0 ..< 3 {
            await session.ingest(chunkBuffer())
        }

        XCTAssertTrue(partials(recorder.events).contains("guten"), "partial emitted while speaking")
        XCTAssertTrue(finals(recorder.events).isEmpty, "no final without a speechEnd")
    }

    /// A sub-second utterance (below the 1 s minimum) is dropped as noise
    /// rather than finalized.
    func testSubSecondUtteranceDroppedAsNoise() async {
        let manager = MockNemotronManager()
        await manager.setFinish("äh")
        let recorder = EventRecorder()
        let session = makeSession(
            manager: manager,
            detector: ScriptedBoundaryDetector(script: [.speechStart, .speechEnd]),
            recorder: recorder,
        )

        for _ in 0 ..< 2 {
            await session.ingest(chunkBuffer())
        }

        // 1 chunk of speech = 4096 samples = 0.256 s < 1 s minimum → dropped.
        XCTAssertTrue(finals(recorder.events).isEmpty, "sub-second speech dropped")
    }

    /// Each utterance finalizes its own complete text via `finish()`, with no
    /// carry-over between utterances.
    func testEachUtteranceFinalizesItsOwnText() async {
        let manager = MockNemotronManager()
        let recorder = EventRecorder()
        let session = makeSession(
            manager: manager,
            detector: ScriptedBoundaryDetector(script: [
                .speechStart, nil, nil, nil, .speechEnd, // utterance 1
                .speechStart, nil, nil, nil, .speechEnd, // utterance 2
            ]),
            recorder: recorder,
        )

        await manager.setFinish("erster satz")
        for _ in 0 ..< 5 {
            await session.ingest(chunkBuffer())
        }
        await manager.setFinish("zweiter satz")
        for _ in 0 ..< 5 {
            await session.ingest(chunkBuffer())
        }

        XCTAssertEqual(finals(recorder.events).map(\.text), ["erster satz", "zweiter satz"])
    }

    /// A dropped sub-second utterance must NOT leak its text into the next
    /// utterance's final — `finish()` clears the manager's accumulation even on
    /// the drop path, so the next final carries only its own text.
    func testDroppedUtteranceDoesNotLeakIntoNextFinal() async {
        let manager = MockNemotronManager()
        let recorder = EventRecorder()
        let session = makeSession(
            manager: manager,
            detector: ScriptedBoundaryDetector(script: [
                .speechStart, .speechEnd, // utterance 1: sub-second, dropped
                .speechStart, nil, nil, nil, .speechEnd, // utterance 2
            ]),
            recorder: recorder,
        )

        await manager.setFinish("äh") // dropped as noise (1 chunk)
        for _ in 0 ..< 2 {
            await session.ingest(chunkBuffer())
        }
        await manager.setFinish("hallo welt")
        for _ in 0 ..< 5 {
            await session.ingest(chunkBuffer())
        }

        XCTAssertEqual(finals(recorder.events).map(\.text), ["hallo welt"], "dropped 'äh' must not leak")
    }

    /// `flush()` (recorder stopped mid-utterance, no `speechEnd`) commits the
    /// pending speech as a final via `finish()`.
    func testFlushCommitsPendingTailUtterance() async {
        let manager = MockNemotronManager()
        await manager.setFinish("letzter satz")
        let recorder = EventRecorder()
        let session = makeSession(
            manager: manager,
            detector: ScriptedBoundaryDetector(script: [.speechStart, nil, nil, nil]),
            recorder: recorder,
        )

        for _ in 0 ..< 4 {
            await session.ingest(chunkBuffer())
        }
        await session.flush()

        XCTAssertEqual(finals(recorder.events).map(\.text), ["letzter satz"], "tail committed on flush")
    }

    /// Speech that runs past the 5 s force-flush without a `speechEnd` emits a
    /// final so the overlay isn't stuck on a growing partial.
    func testForceFlushEmitsFinalAfterFiveSeconds() async {
        let manager = MockNemotronManager()
        await manager.setFinish("langer monolog")
        let recorder = EventRecorder()
        // start + 20×none = 21 chunks ≈ 5.4 s of speech → crosses forceFlushSamples.
        let script: [FluidVAD.StreamEvent.Kind?] = [.speechStart] + Array(repeating: nil, count: 20)
        let session = makeSession(
            manager: manager,
            detector: ScriptedBoundaryDetector(script: script),
            recorder: recorder,
        )

        for _ in 0 ..< 21 {
            await session.ingest(chunkBuffer())
        }

        XCTAssertFalse(finals(recorder.events).isEmpty, "force-flush emits a final past 5 s")
        XCTAssertEqual(finals(recorder.events).first?.text, "langer monolog")
    }
}

// MARK: - Test doubles

/// Scriptable `UtteranceBoundaryDetecting`: returns the next scripted event per
/// chunk (nil = no boundary), so tests drive utterance segmentation
/// deterministically without the Silero model.
private actor ScriptedBoundaryDetector: UtteranceBoundaryDetecting {
    private var script: [FluidVAD.StreamEvent.Kind?]

    init(script: [FluidVAD.StreamEvent.Kind?]) {
        self.script = script
    }

    // swiftlint:disable:next async_without_await
    func boundary(in _: [Float]) async -> FluidVAD.StreamEvent.Kind? {
        script.isEmpty ? nil : script.removeFirst()
    }

    // swiftlint:disable:next async_without_await
    func reset() async {}
}

/// Mock `NemotronStreamingAsrManaging` modelling the real contract:
/// `latestTranscript()` returns the in-progress partial; `finish()` returns the
/// complete utterance text and CLEARS both (the real `finish()` clears its
/// accumulated tokens while keeping encoder state).
private actor MockNemotronManager: NemotronStreamingAsrManaging {
    private var partial = ""
    private var finishText = ""

    func setPartial(_ text: String) {
        partial = text
    }

    func setFinish(_ text: String) {
        finishText = text
    }

    // swiftlint:disable:next async_without_await
    func prepare() async {}

    // swiftlint:disable:next async_without_await
    func process(_: [Float]) async {}

    func latestTranscript() -> String? {
        partial.isEmpty ? nil : partial
    }

    // swiftlint:disable:next async_without_await
    func finish() async -> String {
        let result = finishText
        partial = ""
        finishText = ""
        return result
    }

    // swiftlint:disable:next async_without_await
    func reset() async {
        partial = ""
        finishText = ""
    }
}

/// Thread-safe sink for the session's `@Sendable` event callback.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StreamingTranscriber.Event] = []

    func record(_ event: StreamingTranscriber.Event) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [StreamingTranscriber.Event] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
