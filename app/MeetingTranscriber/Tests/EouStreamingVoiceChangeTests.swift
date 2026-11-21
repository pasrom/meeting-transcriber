import AudioTapLib
@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// `EouStreamingCaptionSession` ending a line where the voice changes.
final class EouStreamingVoiceChangeTests: XCTestCase {
    /// Fires one scripted partial per `processBufferedAudio()` (nil: none), and an EOU with the
    /// transcript at the calls listed in `eouAt`.
    private actor ScriptedPartials: EouStreamingAsrManaging {
        private var partials: [String?]
        private let eouAt: Set<Int>
        private var calls = 0
        private var partialCallback: (@Sendable (String) -> Void)?
        private var eouCallback: (@Sendable (String) -> Void)?

        init(_ partials: [String?], eouAt: Set<Int> = []) {
            self.partials = partials
            self.eouAt = eouAt
        }

        func loadModels() {}
        func appendAudio(_: AVAudioPCMBuffer) {}
        func processBufferedAudio() {
            defer { calls += 1 }
            guard !partials.isEmpty, let partial = partials.removeFirst() else { return }
            partialCallback?(partial)
            if eouAt.contains(calls) { eouCallback?(partial) }
        }

        func finish() -> String {
            ""
        }

        func reset() {}
        func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) {
            partialCallback = callback
        }

        func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) {
            eouCallback = callback
        }

        func getEouTimestampsMs() -> [Int] {
            []
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [StreamingTranscriber.Event] = []
        private var probes: [String]
        private(set) var probeCount = 0

        init(probes: [String] = []) {
            self.probes = probes
        }

        func setProbes(_ probes: [String]) {
            lock.withLock { self.probes = probes }
        }

        func record(_ event: StreamingTranscriber.Event) {
            lock.withLock { events.append(event) }
        }

        /// Nearest voice per probed window, in order.
        func probe() -> LiveSpeakerMatch {
            lock.withLock {
                probeCount += 1
                guard !probes.isEmpty else { return .unknown }
                return LiveSpeakerMatch(name: nil, closest: probes.removeFirst(), distance: 0.3, margin: 0.3)
            }
        }

        var finals: [(text: String, audio: [Float])] {
            lock.withLock {
                events.compactMap { if case let .finalized(text, audio) = $0 { (text, audio) } else { nil } }
            }
        }

        var partials: [String] {
            lock.withLock { events.compactMap { if case let .partial(text) = $0 { text } else { nil } } }
        }

        var voices: [String] {
            lock.withLock { events.compactMap { if case let .voiceChanged(voice) = $0 { voice } else { nil } } }
        }
    }

    private func makeSession(_ asr: ScriptedPartials, _ recorder: Recorder) -> EouStreamingCaptionSession {
        EouStreamingCaptionSession(
            asr: asr,
            channelLabel: "test",
            voiceProbe: { _ in recorder.probe() },
            onEvent: { event in recorder.record(event) },
        )
    }

    /// Samples equal to their index, so a slice can be checked by value.
    private func ramp(from base: Int, count: Int) -> LiveAudioBuffer {
        LiveAudioBuffer(samples: (base ..< base + count).map(Float.init), channelCount: 1, sampleRate: 16000, hostTime: 0)
    }

    /// Windows end every 0.5 s from 1.5 s: A is confirmed at 1.5, 2.0 and 2.5 s, and B at 3.0, 3.5
    /// and 4.0 s, so B starts at 2.25 s, the middle of its first window.
    private static let changeAtTwoPointTwoFive = Array(repeating: "Speaker A", count: 3) + Array(repeating: "Speaker B", count: 3)

    private func ingest(_ session: EouStreamingCaptionSession, chunks: Int, from first: Int = 0) async {
        for index in first ..< first + chunks {
            await session.ingest(ramp(from: index * 8000, count: 8000))
        }
    }

    /// The line ends where the new voice starts, with only the audio before it, and the rest of
    /// the speech stays live text; it held the previous speaker's words under the next one's name.
    func testVoiceChangeEndsTheLineWhereTheNewVoiceStarts() async {
        let asr = ScriptedPartials([
            "what", "what is", "what is the", "what is the gap", "what is the gap", "what is the gap i",
            "what is the gap i have", "what is the gap i have no", "what is the gap i have no idea",
        ])
        let recorder = Recorder(probes: Self.changeAtTwoPointTwoFive)
        let session = makeSession(asr, recorder)
        await ingest(session, chunks: 9)

        XCTAssertEqual(recorder.voices, ["Speaker B"])
        XCTAssertEqual(recorder.finals.map(\.text), ["what is the gap"])
        XCTAssertEqual(recorder.finals.first?.audio, (0 ..< 36000).map(Float.init))
        XCTAssertEqual(recorder.partials.last, "i have no idea")
    }

    /// A word shows in the transcript about one chunk after it is spoken, so the last word before
    /// the change (here "gap", in the partial at 2.5 s for a change at 2.25 s) stays on the line.
    func testWordTranscribedJustAfterTheChangeStaysOnTheLineBeforeIt() async {
        let asr = ScriptedPartials([
            "what", "what is", "what is the", "what is the", "what is the gap", "what is the gap i have",
            "what is the gap i have no", "what is the gap i have no idea",
        ])
        let recorder = Recorder(probes: Self.changeAtTwoPointTwoFive)
        let session = makeSession(asr, recorder)
        await ingest(session, chunks: 9)

        XCTAssertEqual(recorder.finals.map(\.text), ["what is the gap"])
        XCTAssertEqual(recorder.partials.last, "i have no idea")
    }

    /// A reset starts the detector and the probe clock over: the first voice after it is no change,
    /// and its windows are probed from the reset's 1.5 s on.
    func testResetStartsTheDetectorAndTheProbeClockOver() async {
        let recorder = Recorder(probes: ["Speaker A", "Speaker A", "Speaker A", "Speaker B", "Speaker B", "Speaker B"])
        let session = makeSession(ScriptedPartials([]), recorder)
        await ingest(session, chunks: 5)
        await session.reset()
        await ingest(session, chunks: 5)
        XCTAssertEqual(recorder.probeCount, 6)
        XCTAssertEqual(recorder.voices, [])
    }

    /// Words from before a reset are not committed again by a change after it.
    func testResetDropsTheTranscriptHistory() async {
        let asr = ScriptedPartials(["old words", nil, nil, nil, nil, nil, "new words", "new words here", "new words here now"])
        let recorder = Recorder()
        let session = makeSession(asr, recorder)
        await ingest(session, chunks: 1)
        await session.reset()
        recorder.setProbes(Self.changeAtTwoPointTwoFive)
        await ingest(session, chunks: 8, from: 1)
        XCTAssertEqual(recorder.voices, ["Speaker B"])
        XCTAssertEqual(recorder.finals.map(\.text), [])
    }

    /// An EOU finalizes its words and rebases the splitter; a change after it must not commit
    /// those words a second time.
    func testEouDropsTheTranscriptHistory() async {
        let asr = ScriptedPartials(
            ["old words", nil, nil, nil, nil, "old words new words", "old words new words here", "old words new words here now"],
            eouAt: [0],
        )
        let recorder = Recorder(probes: Self.changeAtTwoPointTwoFive)
        let session = makeSession(asr, recorder)
        await ingest(session, chunks: 8)
        XCTAssertEqual(recorder.voices, ["Speaker B"])
        XCTAssertEqual(recorder.finals.map(\.text), ["old words"])
    }

    /// Behind live audio, as while the auto-detect hold replays, windows are not probed.
    func testWindowsAreNotProbedWhileTheFeedIsBehind() async {
        let recorder = Recorder()
        let session = makeSession(ScriptedPartials([]), recorder)
        let behind = EouStreamingCaptionSession.maxProbeBacklog + 0.1
        for index in 0 ..< 5 {
            await session.ingest(ramp(from: index * 8000, count: 8000)) { behind }
        }
        XCTAssertEqual(recorder.probeCount, 0)
        await session.ingest(ramp(from: 40000, count: 8000)) { EouStreamingCaptionSession.maxProbeBacklog }
        XCTAssertEqual(recorder.probeCount, 1)
    }

    /// Windows just under the RMS floor are silence; just over it they are probed.
    func testWindowsUnderTheRmsFloorAreNotProbed() async {
        let recorder = Recorder()
        let session = makeSession(ScriptedPartials([]), recorder)
        func constant(_ level: Float) -> LiveAudioBuffer {
            LiveAudioBuffer(samples: [Float](repeating: level, count: 24000), channelCount: 1, sampleRate: 16000, hostTime: 0)
        }
        await session.ingest(constant(EouStreamingCaptionSession.minProbeRMS * 0.9))
        XCTAssertEqual(recorder.probeCount, 0)
        await session.ingest(constant(EouStreamingCaptionSession.minProbeRMS * 1.1))
        XCTAssertGreaterThan(recorder.probeCount, 0)
    }

    func testSilentWindowsAreNotProbed() async {
        let recorder = Recorder()
        let session = makeSession(ScriptedPartials([]), recorder)
        let silence = [Float](repeating: 0, count: 48000)
        await session.ingest(LiveAudioBuffer(samples: silence, channelCount: 1, sampleRate: 16000, hostTime: 0))
        XCTAssertEqual(recorder.probeCount, 0)
        await session.ingest(ramp(from: 0, count: 8000))
        XCTAssertEqual(recorder.probeCount, 1, "one 0.5 s hop past the silence")
    }
}
