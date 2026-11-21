import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The coordinator's side of the live transcript file: the setting read per
/// recording, and the files it ends when no stop-time flush would.
@MainActor
final class LiveTranscriptionCoordinatorTranscriptFileTests: XCTestCase {
    /// A controller whose `prepare()` loads no models.
    private func mockControllerFactory() -> LiveTranscriptionCoordinator.ControllerFactory {
        { engine, captions, engineLanguage, verboseDiagnostics in
            LiveTranscriptionController(
                engine: engine,
                vad: FluidVAD(threshold: 0.5),
                captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(),
                engineLanguage: engineLanguage,
                eouSessionFactory: { MockEouManager(loadError: nil) },
                verboseDiagnostics: { verboseDiagnostics() },
            )
        }
    }

    /// The setting is read per recording: off writes no file, on opens one per recording start.
    func testTranscriptFileFollowsTheSettingAtEachRecordingStart() async throws {
        let directory = makeTempFile(suffix: "-CoordinatorTranscript")
        var fileEnabled = false
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            transcriptFileEnabled: { fileEnabled },
            transcriptDirectory: directory,
            recorderStarted: { _ in true },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() }

        await coordinator.attachSinks(to: DualSourceRecorder())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "off writes nothing")

        fileEnabled = true
        await coordinator.flush()
        await coordinator.attachSinks(to: DualSourceRecorder())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1, "on opens one file for the recording")
        XCTAssertEqual(files.first?.hasSuffix("_live.jsonl"), true)
    }

    /// A recorder whose start fails never reaches `.recording`, so no stop-time flush
    /// would end the file `attachSinks` opened for it. It holds nothing but `start`, and
    /// a start that keeps failing would leave one such file per retry, so it is removed.
    func testAFileOpenedForARecorderThatNeverStartsIsRemoved() async {
        let directory = makeTempFile(suffix: "-CoordinatorUnstarted")
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            transcriptFileEnabled: { true },
            transcriptDirectory: directory,
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() }

        await coordinator.attachSinks(to: DualSourceRecorder())

        let fileCount = { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count }
        await waitFor({ fileCount() == 0 }, timeout: .seconds(5))
        XCTAssertEqual(fileCount(), 0, "no file is left for a recording that never started")
    }

    /// Dropping a controller, for a settings change while idle, ends the file it held.
    func testDroppingAControllerEndsItsFile() async throws {
        let directory = makeTempFile(suffix: "-CoordinatorDrop")
        let suiteName = "LiveTxCoordTests-\(getpid())-\(UUID().uuidString)"
        defer { DefaultsSuite.remove(suiteName) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suiteName)))
        settings.transcriptionEngine = .parakeet
        settings.liveTranscriptionEnabled = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { settings.liveTranscriptionEnabled },
            engineSupportsLive: { settings.transcriptionEngine.supportsLiveTranscription },
            verboseDiagnostics: { false },
            transcriptFileEnabled: { true },
            transcriptDirectory: directory,
            recorderStarted: { _ in true },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() }
        await coordinator.attachSinks(to: DualSourceRecorder())
        let fileText: () -> String = {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.first.flatMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) } ?? ""
        }
        XCTAssertFalse(fileText().isEmpty, "precondition: the recording has a file")
        XCTAssertFalse(fileText().contains(#""type":"end""#), "precondition: a started recorder keeps it open")

        settings.liveTranscriptionEnabled = false
        await waitFor({ fileText().contains(#""type":"end""#) }, timeout: .seconds(5))

        XCTAssertTrue(fileText().contains(#""type":"end""#))
    }

    /// The end the stop-time flush starts is held where a quit looks for it, the
    /// coordinator's shared ends, not only in the controller that started it.
    func testAStopTimeEndIsHeldWhereAQuitWaits() async throws {
        let directory = makeTempFile(suffix: "-CoordinatorQuitEnd")
        var built: LiveTranscriptionController?
        let base = mockControllerFactory()
        let capturing: LiveTranscriptionCoordinator.ControllerFactory = { engine, captions, language, verbose in
            let controller = base(engine, captions, language, verbose)
            built = controller
            return controller
        }
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { true },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            transcriptFileEnabled: { true },
            transcriptDirectory: directory,
            recorderStarted: { _ in true },
            makeController: capturing,
        )
        coordinator.beginPrewarm { MockStreamingEngine() }
        await coordinator.attachSinks(to: DualSourceRecorder())
        let file = try XCTUnwrap(built?.transcriptFile)
        file.eventsInFlight.enter() // a speaker match still running at the stop

        await coordinator.flush()
        XCTAssertFalse(coordinator.transcriptEnds.isEmpty, "a quit now must wait for this end")
        file.eventsInFlight.leave()
        await coordinator.transcriptEnds.waitForAll()

        XCTAssertTrue(try String(contentsOf: file.url, encoding: .utf8).contains(#""type":"end""#))
    }

    /// A call split into a recording that gets no captions (live captions turned off
    /// during the call) runs no flush and no `prepareForNextRecording()`, so the
    /// previous call's file is ended when its sinks are not attached.
    func testACallSplitIntoARecordingWithoutCaptionsEndsThePreviousFile() async throws {
        let directory = makeTempFile(suffix: "-CoordinatorSplitOff")
        var liveEnabled = true
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { liveEnabled },
            engineSupportsLive: { true },
            verboseDiagnostics: { false },
            transcriptFileEnabled: { true },
            transcriptDirectory: directory,
            recorderStarted: { _ in true },
            makeController: mockControllerFactory(),
        )
        coordinator.beginPrewarm { MockStreamingEngine() }
        await coordinator.attachSinks(to: DualSourceRecorder())
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        let fileText = { (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "" }

        liveEnabled = false
        await coordinator.attachSinks(to: DualSourceRecorder())
        await coordinator.transcriptEnds.waitForAll()

        XCTAssertTrue(fileText().contains(#""type":"end""#), "the previous call's reader would wait until the next call stops")
    }

    /// Emits a last final when flushed, a moment later, like an engine committing the
    /// tail of a recording at stop.
    private actor SlowTailPipeline: LiveCaptionPipeline {
        private let sink: StreamingTranscriber.EventSink

        init(sink: @escaping StreamingTranscriber.EventSink) {
            self.sink = sink
        }

        func ingest(_: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {}
        func reset() {}
        func flush() async {
            try? await Task.sleep(for: .milliseconds(300))
            sink(.finalized(text: "the tail", audio: []))
        }
    }

    private actor IdlePipeline: LiveCaptionPipeline {
        func ingest(_: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {}
        func reset() {}
        // swiftlint:disable:next async_without_await
        func flush() async {}
    }

    /// A call split into a recording without captions while the last recording's
    /// stop-time flush still runs: the flush ends the file after its tail final.
    func testAnAttachWithoutCaptionsLetsARunningFlushFinishTheFile() async throws {
        let directory = makeTempFile(suffix: "-CoordinatorFlushRunning")
        var liveEnabled = true
        var built: LiveTranscriptionController?
        let pipelines: LiveTranscriptionController.NemotronPipelineFactory = { _, _, makeSink in
            (SlowTailPipeline(sink: makeSink(.mic)), IdlePipeline())
        }
        let factory: LiveTranscriptionCoordinator.ControllerFactory = { engine, captions, _, _ in
            let controller = LiveTranscriptionController(
                engine: engine, vad: FluidVAD(threshold: 0.5), captions: captions,
                speakerMatcher: FakeLiveSpeakerMatcher(), engineLanguage: "de",
                nemotronPipelineFactory: pipelines,
            )
            built = controller
            return controller
        }
        let coordinator = LiveTranscriptionCoordinator(
            captions: LiveCaptionsState(),
            liveEnabled: { liveEnabled },
            engineSupportsLive: { true },
            engineLanguage: { "de" },
            verboseDiagnostics: { false },
            transcriptFileEnabled: { true },
            transcriptDirectory: directory,
            recorderStarted: { _ in true },
            makeController: factory,
        )
        coordinator.beginPrewarm { MockStreamingEngine() }
        await waitFor(coordinator.warmup == .ready, timeout: .seconds(5))
        await coordinator.attachSinks(to: DualSourceRecorder())
        let controller = try XCTUnwrap(built)
        let file = try XCTUnwrap(controller.transcriptFile)

        let flush = controller.beginFlush()
        liveEnabled = false
        await coordinator.attachSinks(to: DualSourceRecorder())
        await flush.value
        await coordinator.transcriptEnds.waitForAll()

        let types = try String(contentsOf: file.url, encoding: .utf8).split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])["type"] as? String
        }
        XCTAssertEqual(types, ["start", "final", "end"], "the tail final must not be cut off by an early end")
    }
}
