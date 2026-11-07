import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// A reimport carries the sidecar's mute times only with a mic track. Without
/// one the single-source branch transcribes the mix, which holds the far end,
/// and those times would silence it.
@MainActor
final class MicMuteReimportTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    private let muted = [MicMuteInterval(start: 0, end: 30)]

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "mic-mute-reimport")
    }

    /// Imports the given suffixes of an app recording `m`, whose sidecar holds
    /// a mute over the whole of it.
    private func importing(_ suffixes: [String], engine: MockEngine = MockEngine()) throws -> PipelineController {
        let suite = "MicMuteReimportTests-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: tmpDir)
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let controller = PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: PipelineQueue(
                engine: engine, diarizationFactory: { MockDiarization() },
                protocolGeneratorFactory: { MockProtocolGen() }, outputDir: tmpDir, logDir: tmpDir,
                stagingDir: tmpDir.appendingPathComponent("staging"),
                diarizeEnabled: false, echoDedupEnabled: false,
            )),
        )
        let urls = suffixes.map { tmpDir.appendingPathComponent("m" + $0) }
        for url in urls {
            try AudioMixer.saveWAV(
                samples: [Float](repeating: 0.05, count: 30 * AudioConstants.targetSampleRate),
                sampleRate: AudioConstants.targetSampleRate, url: url,
            )
        }
        try RecordingSidecar(
            title: "t", appName: "Teams", startedAt: Date(), stoppedAt: Date(),
            participants: [], micDelaySeconds: 0, trigger: .manual, mixFilename: "m_mix.wav",
            appFilename: "m_app.wav", micFilename: "m_mic.wav", micMuteIntervals: muted,
        ).write(toDirectory: tmpDir, basename: "m")

        controller.enqueueFiles(urls)
        return controller
    }

    /// The `_mic.wav` did not arrive: the app text survives and no mute is shown.
    func testAppTrackWithoutAMicTrackKeepsTheFarEnd() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 11, end: 13, text: "far end speaking")]
        let controller = try importing([RecordingFileSuffix.mix, RecordingFileSuffix.app], engine: engine)
        let job = try XCTUnwrap(controller.queue.jobs.first)
        XCTAssertNotNil(job.appPath, "test premise: the app track was imported")
        XCTAssertNil(job.micPath, "test premise: the mic track was not")

        await controller.queue.processNext()
        let finished = try XCTUnwrap(controller.queue.job(withID: job.id))
        let transcript = try String(contentsOf: XCTUnwrap(finished.transcriptPath), encoding: .utf8)

        XCTAssertNotEqual(finished.state, .error)
        XCTAssertTrue(transcript.contains("far end speaking"))
        XCTAssertFalse(transcript.contains("Mic muted"))
    }

    /// A lone `_mix.wav` is a paired group too, so it reads the sidecar.
    func testOnlyTheMixCarriesNoMuteTimes() throws {
        let job = try XCTUnwrap(importing([RecordingFileSuffix.mix]).queue.jobs.first)
        XCTAssertTrue(job.micMuteSpansOnTranscript.isEmpty)
    }

    func testBothTracksCarryTheMuteTimes() throws {
        let job = try XCTUnwrap(importing([RecordingFileSuffix.app, RecordingFileSuffix.mic]).queue.jobs.first)
        XCTAssertEqual(job.micMuteSpansOnTranscript, muted)
    }
}
