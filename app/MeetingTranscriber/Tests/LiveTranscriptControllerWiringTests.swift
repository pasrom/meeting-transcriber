import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The controller writes every engine's finals through the one event sink, and
/// only while a transcript file is open for the recording.
@MainActor
final class LiveTranscriptControllerWiringTests: XCTestCase {
    /// A fresh folder path per test, removed when the test ends. Reserved, not created
    /// (`makeTempDirectory` would create it with default permissions), so the tests
    /// see the folder mode the code under test sets.
    private lazy var directory = makeTempFile(suffix: "-LiveTranscriptWiringTests")

    private actor NoopPipeline: LiveCaptionPipeline {
        func ingest(_: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {}
        func reset() {}
        // swiftlint:disable:next async_without_await
        func flush() async {}
    }

    /// Emits a final for every buffer it ingests, a moment later, like an engine
    /// finishing a line: the delay keeps the feed busy past the point where a call
    /// split would otherwise swap files.
    private actor EmittingPipeline: LiveCaptionPipeline {
        private let sink: StreamingTranscriber.EventSink

        init(sink: @escaping StreamingTranscriber.EventSink) {
            self.sink = sink
        }

        func ingest(_: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) async {
            try? await Task.sleep(for: .milliseconds(300))
            sink(.finalized(text: "held by the feed", audio: []))
        }

        func reset() {}
        // swiftlint:disable:next async_without_await
        func flush() async {}
    }

    /// Keeps the event sinks the controller hands its streaming pipelines, so a
    /// test can emit a final exactly as an engine would.
    @MainActor
    private final class SinkCapture {
        var sinks: [LiveCaptionChannel: StreamingTranscriber.EventSink] = [:]

        func factory() -> LiveTranscriptionController.NemotronPipelineFactory {
            { _, _, makeSink in
                self.sinks[.mic] = makeSink(.mic)
                self.sinks[.app] = makeSink(.app)
                return (NoopPipeline(), NoopPipeline())
            }
        }
    }

    private func makeController(capture: SinkCapture, matcher: FakeLiveSpeakerMatcher) -> LiveTranscriptionController {
        LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: matcher,
            engineLanguage: "de",
            nemotronPipelineFactory: capture.factory(),
        )
    }

    private func waitForLines(in url: URL, count: Int, within budget: Duration = .seconds(10)) async throws -> [[String: Any]] {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n")
            if lines.count >= count {
                return try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("transcript never reached \(count) lines")
        return []
    }

    func testFinalAndLateSpeakerMatchAreWrittenForTheRecording() async throws {
        let capture = SinkCapture()
        let controller = makeController(capture: capture, matcher: FakeLiveSpeakerMatcher(canned: ["Speaker A"]))
        var opened: [LiveTranscriptFile] = []
        controller.transcriptFileFactory = { [directory] in
            let file = LiveTranscriptFile.open(in: directory)
            if let file { opened.append(file) }
            return file
        }
        await controller.prepare()
        await controller.prepareForNextRecording()

        let sink = try XCTUnwrap(capture.sinks[.mic])
        sink(.finalized(text: "create a ticket for the login bug", audio: [Float](repeating: 0, count: 16000)))

        let file = try XCTUnwrap(opened.first)
        let events = try await waitForLines(in: file.url, count: 3)
        XCTAssertEqual(events.map { $0["type"] as? String }, ["start", "final", "speaker"])
        guard events.count == 3 else { return }
        XCTAssertEqual(events[1]["text"] as? String, "create a ticket for the login bug")
        XCTAssertEqual(events[1]["channel"] as? String, "mic")
        XCTAssertEqual(events[1]["speaker"] as? String, "Me", "the line is written at once, under the channel label")
        XCTAssertEqual(events[2]["speaker"] as? String, "Speaker A", "the match lands as its own event")
        XCTAssertEqual(events[2]["seq"] as? Int, events[1]["seq"] as? Int)

        await controller.flush()
        let afterFlush = try await waitForLines(in: file.url, count: 4)
        XCTAssertEqual(afterFlush.last?["type"] as? String, "end")
    }

    /// A call split opens the next recording's file without a flush. A final handed
    /// over before that still belongs to the call it was spoken in.
    func testFinalHandedOverBeforeACallSplitStaysInItsOwnFile() async throws {
        let capture = SinkCapture()
        let controller = makeController(capture: capture, matcher: FakeLiveSpeakerMatcher())
        controller.transcriptFileFactory = { [directory] in LiveTranscriptFile.open(in: directory) }
        await controller.prepare()
        await controller.prepareForNextRecording()
        let first = try XCTUnwrap(controller.transcriptFile)

        try XCTUnwrap(capture.sinks[.mic])(.finalized(text: "end of the first call", audio: []))
        await controller.prepareForNextRecording()
        let second = try XCTUnwrap(controller.transcriptFile)

        let firstEvents = try await waitForLines(in: first.url, count: 3)
        XCTAssertEqual(firstEvents.map { $0["type"] as? String }, ["start", "final", "end"])
        XCTAssertEqual(firstEvents.first { $0["type"] as? String == "final" }?["text"] as? String, "end of the first call")
        let secondText = try String(contentsOf: second.url, encoding: .utf8)
        XCTAssertFalse(secondText.contains("\"final\""), "the next call's file must not get the previous call's words")
    }

    /// `end` is the last line of a recording: ending the file waits for the finals and
    /// speaker matches still in flight, which each sink event's own main-actor hop and
    /// the match itself would otherwise let `end` overtake.
    func testEndComesAfterTheLastFinalAndItsSpeakerMatch() async throws {
        let capture = SinkCapture()
        let controller = makeController(
            capture: capture,
            matcher: FakeLiveSpeakerMatcher(canned: ["Speaker A"], matchDelay: .milliseconds(200)),
        )
        controller.transcriptFileFactory = { [directory] in LiveTranscriptFile.open(in: directory) }
        await controller.prepare()
        await controller.prepareForNextRecording()
        let file = try XCTUnwrap(controller.transcriptFile)

        try XCTUnwrap(capture.sinks[.app])(.finalized(text: "last words", audio: [Float](repeating: 0, count: 16000)))
        await controller.flush()

        let events = try await waitForLines(in: file.url, count: 4)
        XCTAssertEqual(events.map { $0["type"] as? String }, ["start", "final", "speaker", "end"])
    }

    /// A stuck match neither holds the flush, which the next recording's start awaits,
    /// nor lands after `end`, which follows at the wait's cap. The flush must return in
    /// well under the cap (it would take the whole cap if it waited), and the match
    /// outlasts the cap and the wait for the lines (it would land first if the cap
    /// were ignored).
    func testAStuckMatchHoldsNeitherTheFlushNorTheEnd() async throws {
        let capture = SinkCapture()
        let controller = makeController(
            capture: capture,
            matcher: FakeLiveSpeakerMatcher(canned: ["Speaker A"], matchDelay: .seconds(30)),
        )
        controller.transcriptFileFactory = { [directory] in LiveTranscriptFile.open(in: directory) }
        controller.transcriptEndWait = .seconds(4)
        await controller.prepare()
        await controller.prepareForNextRecording()
        let file = try XCTUnwrap(controller.transcriptFile)

        try XCTUnwrap(capture.sinks[.mic])(.finalized(text: "stuck", audio: [Float](repeating: 0, count: 16000)))
        let started = ContinuousClock.now
        await controller.flush()

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "the flush does not wait for the end")
        let events = try await waitForLines(in: file.url, count: 3, within: .seconds(20))
        XCTAssertEqual(events.map { $0["type"] as? String }, ["start", "final", "end"])
    }

    /// Audio the last recording's feed still holds at a call split is turned into its
    /// finals before the next file opens, so they go to the call they were spoken in.
    func testAudioTheFeedHoldsAtACallSplitIsWrittenToItsOwnCall() async throws {
        let pipelines: LiveTranscriptionController.NemotronPipelineFactory = { _, _, makeSink in
            (EmittingPipeline(sink: makeSink(.mic)), NoopPipeline())
        }
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: LiveCaptionsState(),
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "de",
            nemotronPipelineFactory: pipelines,
        )
        controller.transcriptFileFactory = { [directory] in LiveTranscriptFile.open(in: directory) }
        await controller.prepare()
        await controller.prepareForNextRecording()
        let first = try XCTUnwrap(controller.transcriptFile)

        controller.micSink(LiveAudioBuffer(samples: [Float](repeating: 0, count: 1600), channelCount: 1, sampleRate: 16000, hostTime: 0))
        await controller.prepareForNextRecording()
        let second = try XCTUnwrap(controller.transcriptFile)

        let firstEvents = try await waitForLines(in: first.url, count: 3)
        XCTAssertEqual(firstEvents.map { $0["type"] as? String }, ["start", "final", "end"])
        let secondText = try String(contentsOf: second.url, encoding: .utf8)
        XCTAssertFalse(secondText.contains("held by the feed"), "the next call's file must not get the previous call's words")
    }

    /// A write that fails turns the file off for the recording; captions go on.
    func testAFailedWriteTurnsTheFileOffWithoutTouchingCaptions() async throws {
        try XCTSkipIf(geteuid() == 0, "root writes to a read-only file regardless")
        let capture = SinkCapture()
        let captions = LiveCaptionsState()
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "de",
            nemotronPipelineFactory: capture.factory(),
        )
        controller.transcriptFileFactory = { [directory] in LiveTranscriptFile.open(in: directory) }
        await controller.prepare()
        await controller.prepareForNextRecording()
        let file = try XCTUnwrap(controller.transcriptFile)
        let sink = try XCTUnwrap(capture.sinks[.mic])

        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.url.path)
        sink(.finalized(text: "not written", audio: []))
        await waitFor(captions.recentFinals.count == 1, timeout: .seconds(5))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        sink(.finalized(text: "file is off", audio: []))
        await waitFor(captions.recentFinals.count == 2, timeout: .seconds(5))

        XCTAssertEqual(captions.recentFinals.map(\.text), ["not written", "file is off"], "captions are unaffected")
        let types = try String(contentsOf: file.url, encoding: .utf8).split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])["type"] as? String
        }
        XCTAssertEqual(types, ["start"], "after a failed write nothing more is written, not even once writable again")
    }

    func testNoFileFactoryWritesNothing() async throws {
        let capture = SinkCapture()
        let captions = LiveCaptionsState()
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "de",
            nemotronPipelineFactory: capture.factory(),
        )
        await controller.prepare()
        await controller.prepareForNextRecording()

        try XCTUnwrap(capture.sinks[.mic])(.finalized(text: "hello", audio: []))
        await waitFor(!captions.recentFinals.isEmpty, timeout: .seconds(1))

        XCTAssertEqual(captions.recentFinals.count, 1, "captions still run")
        XCTAssertNil(controller.transcriptFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEachRecordingGetsItsOwnFile() async throws {
        let capture = SinkCapture()
        let controller = makeController(capture: capture, matcher: FakeLiveSpeakerMatcher())
        controller.transcriptFileFactory = { [directory] in LiveTranscriptFile.open(in: directory) }
        await controller.prepare()

        await controller.prepareForNextRecording()
        let first = try XCTUnwrap(controller.transcriptFile?.url)
        await controller.flush()
        await controller.prepareForNextRecording()
        let second = try XCTUnwrap(controller.transcriptFile?.url)

        XCTAssertNotEqual(first, second)
    }
}
