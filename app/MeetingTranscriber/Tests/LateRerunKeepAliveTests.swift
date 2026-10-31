import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// A re-run moves its job to `.diarizing` before it returns, so it has to be
/// the one that moves it back, even when nothing else holds the queue by the
/// time its task first runs.
@MainActor
final class LateRerunKeepAliveTests: XCTestCase {
    func testARerunPutsItsJobBackWhenTheQueueIsOtherwiseReleased() async throws {
        let dir = try makeTempDirectory(prefix: "late_rerun_keep_alive")
        let slug = "standup"
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data([0]).write(to: recordings.appendingPathComponent("\(slug)\(SpeakerNamingStore.mixSuffix)"))

        let session = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: PipelineQueue.throwawayMatcherFactory(),
            diarizationFactory: { MockDiarization() },
            outputDir: dir,
        )
        let states = StateLog()
        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.namingSlug = slug
        var queue: RecordingDelegate? = RecordingDelegate(job: job, states: states)
        weak let released = queue
        session.delegate = queue
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        XCTAssertNil(session.completeSpeakerNaming(jobID: job.id, result: .rerun(2), source: .dialog))
        let rerun = try XCTUnwrap(session.lateWork[job.id]?.values, "test premise: the re-run started")
        // The last outside reference goes before the re-run's task first runs.
        queue = nil
        for task in rerun {
            await task.value
        }

        XCTAssertEqual(states.entries.last, .speakerNamingPending, "the re-run left its job in \(states.entries)")
        XCTAssertNil(released, "test premise: the delegate was released once the re-run ended")
    }
}

/// State changes, kept apart from the delegate so they outlive it.
@MainActor
private final class StateLog {
    var entries: [JobState] = []
}

/// The smallest delegate a single-source re-run needs, logging state changes
/// into a `StateLog` the test holds on its own.
@MainActor
private final class RecordingDelegate: SpeakerNamingSessionDelegate {
    private var job: PipelineJob
    private let states: StateLog

    init(job: PipelineJob, states: StateLog) {
        self.job = job
        self.states = states
    }

    func job(withID id: UUID) -> PipelineJob? {
        id == job.id ? job : nil
    }

    func updateJobState(id: UUID, to newState: JobState, error _: String?) {
        guard id == job.id else { return }
        job.state = newState
        states.entries.append(newState)
    }

    func addWarning(id _: UUID, _: String) {}

    func setNamingMetadata(jobID _: UUID, slug _: String?, usedDiarizerMode _: DiarizerMode?, wroteSidecarsIn _: URL?) {}

    func updateSpeakerDB(
        matcher _: SpeakerMatcher, mapping _: [String: String],
        embeddings _: [String: [Float]], speakingTimes _: [String: TimeInterval], jobID _: UUID,
    ) {}

    func generateProtocol(jobID _: UUID, transcript _: String, title _: String, protocolsDir _: URL) {}

    func runDualTrackDiarization(
        diarizeProcess _: any DiarizationProvider,
        tracks _: (app: URL, mic: URL, micDelay: TimeInterval, viability: DualTrackViability?),
        speakerCount _: Int?, title _: String, jobID _: UUID,
    ) throws -> DiarizationRun {
        throw DiarizationError.notAvailable
    }

    func renderLabeledTranscript( // swiftlint:disable:this function_parameter_count
        run _: DiarizationRun, cachedSegments _: [TimestampedSegment],
        isDualSource _: Bool, autoNames _: [String: String], note _: String?, micMuted _: [MicMuteInterval],
    ) -> String? {
        nil
    }
}
