@testable import MeetingTranscriber
import XCTest

/// Shared set-up for the queue's retention tests: staging, output and log
/// folders under a fresh temp folder, a retention object reading `enabled` and
/// `days`, and the helpers both test classes use. A fixture object rather than
/// a base class, since test cases keep their members private.
@MainActor
final class RetentionQueueFixture {
    let tmpDir: URL
    let staging: URL
    let output: URL
    let logDir: URL
    // swiftlint:disable:next implicitly_unwrapped_optional
    private(set) var retention: RecordingRetention!
    var enabled = true
    var days = 0

    init(tmpDir: URL) throws {
        self.tmpDir = tmpDir
        staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        output = tmpDir.appendingPathComponent("Output", isDirectory: true)
        logDir = tmpDir.appendingPathComponent("logs", isDirectory: true)
        for dir in [staging, output, logDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        retention = RecordingRetention(
            registry: RecordingRetentionRegistry(
                path: logDir.appendingPathComponent(RecordingRetentionRegistry.filename),
            ),
        ) { [weak self] in
            RecordingRetentionSettings(enabled: self?.enabled ?? false, days: self?.days ?? 0)
        }
    }

    func makeQueue(
        protocolGen: MockProtocolGen? = MockProtocolGen(),
        provider: RetentionProviderSwitch? = nil,
        parksForNaming: Bool = false,
        notion: NotionExportConfiguration? = nil,
        moveArtifact: @escaping (URL, URL) throws -> Void = PipelineQueue.liveMoveArtifact,
    ) -> PipelineQueue {
        let factory: () -> MockProtocolGen? = provider.map { provider in { provider.generator } } ?? { protocolGen }
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        let diar = MockDiarization()
        diar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            // nil runs straight to `.done`; a value parks the job for naming.
            embeddings: parksForNaming ? ["SPEAKER_0": [1, 0, 0]] : nil,
        )
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { diar },
            protocolGeneratorFactory: { factory() },
            outputDir: output,
            logDir: logDir,
            stagingDir: staging,
            diarizeEnabled: true,
            notionExportConfigurationProvider: notion.map { configuration in { .ready(configuration) } },
            inFlightRuns: InFlightRunRegistry(),
            recordingRetention: retention,
            moveArtifact: moveArtifact,
        )
    }

    /// A dual-source recording sitting in staging, as the recorder leaves it.
    func makeRecordedJob(in dir: URL? = nil) throws -> PipelineJob {
        let dir = dir ?? staging
        let stem = "20270115_120000_\(UUID().uuidString.prefix(6))"
        let source = try createTestAudioFile(in: dir)
        let mix = dir.appendingPathComponent("\(stem)\(RecordingFileSuffix.mix)")
        let app = dir.appendingPathComponent("\(stem)\(RecordingFileSuffix.app)")
        let mic = dir.appendingPathComponent("\(stem)\(RecordingFileSuffix.mic)")
        try FileManager.default.moveItem(at: source, to: mix)
        try FileManager.default.copyItem(at: mix, to: app)
        try FileManager.default.copyItem(at: mix, to: mic)
        var job = PipelineJob(
            meetingTitle: "Weekly Sync", appName: "Teams",
            mixPath: mix, appPath: app, micPath: mic, micDelay: 0,
        )
        job.meetingStartTime = Date(timeIntervalSince1970: 1_780_000_000)
        return job
    }

    var recordingsDir: URL {
        output.appendingPathComponent("recordings")
    }

    var protocolsDir: URL {
        output.appendingPathComponent("protocols")
    }

    func relocatedTracks(of job: PipelineJob?) throws -> [URL] {
        let job = try XCTUnwrap(job)
        return try [XCTUnwrap(job.mixPath), XCTUnwrap(job.appPath), XCTUnwrap(job.micPath)]
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Answers every export at once, with a page or with a network error.
struct RetentionNotionExporter: NotionExporting {
    let fail: Bool

    // swiftlint:disable:next function_parameter_count
    func exportMeeting(
        title _: String,
        date _: Date?,
        tags _: [String],
        markdown _: String,
        transcript _: String?,
        existingPageID _: String?,
        onPageCreated: @Sendable (NotionPageResult) async -> Void,
    ) async throws -> NotionPageResult {
        if fail { throw URLError(.notConnectedToInternet) }
        let page = NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
        await onPageCreated(page)
        return page
    }
}

/// The protocol provider setting as a test can flip it while a run is going.
final class RetentionProviderSwitch {
    var generator: MockProtocolGen?

    init(generator: MockProtocolGen?) {
        self.generator = generator
    }
}
