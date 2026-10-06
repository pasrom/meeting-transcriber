@testable import MeetingTranscriber
import XCTest

// The shared harness for driving `SpeakerNamingSession` directly against a mock
// delegate, with no `PipelineQueue` construction.
//
// Its own file because `SpeakerNamingSessionTests` reached the 600-line cap once
// a second group of tests needed the same arrangement. Copying it instead is
// what `SidecarFixture` records going wrong once already, in this same area.

/// Records every delegate callback and models the minimal queue state the
/// session reads back (a per-id job whose `state` `updateJobState` mutates).
@MainActor
final class NamingSessionMockDelegate: SpeakerNamingSessionDelegate {
    var jobs: [UUID: PipelineJob] = [:]
    private(set) var stateTransitions: [(id: UUID, state: JobState)] = []
    private(set) var warnings: [(id: UUID, message: String)] = []
    private(set) var generateProtocolCalls: [(jobID: UUID, title: String, protocolsDir: URL)] = []
    private(set) var updateSpeakerDBCallCount = 0
    /// The embeddings each write actually carried. Recorded separately from the
    /// call count because the echo quarantine is invisible in the count: the
    /// write still happens, it just carries less.
    private(set) var updateSpeakerDBEmbeddings: [[String: [Float]]] = []
    private(set) var metadataUpdates: [(jobID: UUID, slug: String?, mode: DiarizerMode?)] = []
    /// The folder each metadata call claimed to have written to, nil included:
    /// a write that did not land must pass nil, which is what keeps the
    /// recorded order able to say which payload is newest.
    private(set) var recordedSidecarDirs: [URL?] = []
    private(set) var stageStartCount = 0
    private(set) var stageEndCount = 0

    func job(withID id: UUID) -> PipelineJob? {
        jobs[id]
    }

    func updateJobState(id: UUID, to newState: JobState, error _: String?) {
        jobs[id]?.state = newState
        stateTransitions.append((id, newState))
    }

    func addWarning(id: UUID, _ message: String) {
        warnings.append((id, message))
    }

    func setNamingMetadata(
        jobID: UUID, slug: String?, usedDiarizerMode: DiarizerMode?, wroteSidecarsIn: URL?,
    ) {
        metadataUpdates.append((jobID, slug, usedDiarizerMode))
        recordedSidecarDirs.append(wroteSidecarsIn)
    }

    func updateSpeakerDB(
        matcher _: SpeakerMatcher, mapping _: [String: String],
        embeddings: [String: [Float]], speakingTimes _: [String: TimeInterval],
    ) {
        updateSpeakerDBCallCount += 1
        updateSpeakerDBEmbeddings.append(embeddings)
    }

    func generateProtocol(jobID: UUID, transcript _: String, title: String, protocolsDir: URL) {
        generateProtocolCalls.append((jobID, title, protocolsDir))
    }

    func runDualTrackDiarization(
        diarizeProcess _: any DiarizationProvider,
        tracks _: (app: URL, mic: URL, micDelay: TimeInterval, viability: DualTrackViability?),
        speakerCount _: Int?, title _: String, jobID _: UUID,
    ) throws -> DiarizationRun {
        throw DiarizationError.notAvailable
    }

    func renderLabeledTranscript(
        run _: DiarizationRun, cachedSegments _: [TimestampedSegment],
        isDualSource _: Bool, autoNames _: [String: String], note _: String?,
    ) -> String? {
        nil
    }

    func namingStageDidStart(jobID _: UUID) {
        stageStartCount += 1
    }

    func namingStageDidEnd() {
        stageEndCount += 1
    }
}

/// The arrangements these suites share. An enum rather than an `XCTestCase`
/// extension, because a sibling suite carries its own `makeNamingData` and two
/// of those cannot coexist in one namespace.
@MainActor
enum NamingSessionFixture {
    static func session(outputDir: URL?) -> SpeakerNamingSession {
        SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: PipelineQueue.throwawayMatcherFactory(),
            outputDir: outputDir,
        )
    }

    static func namingData(jobID: UUID) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: jobID,
            meetingTitle: "Standup",
            mapping: ["SPEAKER_0": "SPEAKER_0"],
            speakingTimes: ["SPEAKER_0": 12],
            embeddings: ["SPEAKER_0": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )
    }

    /// Digital silence for the given sidecar suffixes of `slug`, so a reader
    /// that measures the app track finds it carrying nothing.
    static func writeSilentTracks(
        slug: String, suffixes: [String], in recordingsDir: URL,
    ) throws {
        for suffix in suffixes {
            try AudioMixer.saveWAV(
                samples: [Float](repeating: 0, count: 16000 * 3), sampleRate: 16000,
                url: recordingsDir.appendingPathComponent("\(slug)\(suffix)"),
            )
        }
    }

    /// A dual-track naming set: one speaker per track, prefixed the way
    /// `mergeDualTrackDiarization` prefixes them.
    static func dualTrackNamingData(
        jobID: UUID, segments: [PipelineQueue.SpeakerNamingData.Segment] = [],
    ) -> PipelineQueue.SpeakerNamingData {
        let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
        let local = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded
        return PipelineQueue.SpeakerNamingData(
            jobID: jobID,
            meetingTitle: "Standup",
            mapping: [remote: remote, local: local],
            speakingTimes: [remote: 30, local: 30],
            embeddings: [remote: [1, 0, 0], local: [0, 1, 0]],
            audioPath: nil,
            segments: segments,
            participants: [],
            isDualSource: true,
        )
    }

    static func pendingJob(
        namingSlug: String?, transcriptPath: URL?, echo: EchoDetectionDTO? = nil,
    ) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Test",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.echo = echo
        job.state = .speakerNamingPending
        job.namingSlug = namingSlug
        job.transcriptPath = transcriptPath
        return job
    }

    /// A detector result with the given per-window correlations, so the tests go
    /// through the real `Result` → DTO mapping rather than asserting against a
    /// hand-built verdict that could disagree with what the detector emits.
    static func echoResult(correlations: [Double]) -> EchoBleedDetector.Result {
        EchoBleedDetector.Result(
            windowScores: correlations.map { correlation in
                EchoBleedDetector.WindowScore(correlation: correlation, lagSeconds: 0.015)
            },
        )
    }
}
