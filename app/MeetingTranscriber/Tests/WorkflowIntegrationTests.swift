// swiftlint:disable file_length
@testable import MeetingTranscriber
import os
import XCTest

@MainActor
final class WorkflowIntegrationTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle type_body_length
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "workflow_test")
    }

    // MARK: - Harness

    private struct Harness {
        let queue: PipelineQueue
        let engine: MockEngine
        let diarization: MockDiarization
        let protocolGen: MockProtocolGen
        let audioPath: URL
    }

    private actor StubNotionExporter: NotionExporting {
        struct Export: Sendable {
            let existingPageID: String?
            let markdown: String
            let transcript: String?
            let tags: [String]
        }

        let result: NotionPageResult
        let fail: Bool
        private var failAfterPageCreatedCount: Int
        private(set) var exports: [Export] = []

        init(result: NotionPageResult, fail: Bool = false, failAfterPageCreatedCount: Int = 0) {
            self.result = result
            self.fail = fail
            self.failAfterPageCreatedCount = failAfterPageCreatedCount
        }

        // swiftlint:disable:next function_parameter_count
        func exportMeeting(
            title _: String,
            date _: Date?,
            tags: [String],
            markdown: String,
            transcript: String?,
            existingPageID: String?,
            onPageCreated: @Sendable (NotionPageResult) async -> Void,
        ) async throws -> NotionPageResult {
            exports.append(Export(existingPageID: existingPageID, markdown: markdown, transcript: transcript, tags: tags))
            if fail { throw URLError(.notConnectedToInternet) }
            await onPageCreated(result)
            if failAfterPageCreatedCount > 0 {
                failAfterPageCreatedCount -= 1
                throw URLError(.networkConnectionLost)
            }
            return result
        }
    }

    /// Reports what is on disk at the moment the export starts.
    private actor LocalFileObservingExporter: NotionExporting {
        let directory: URL
        private(set) var markdownFilesAtExport: [String] = []

        init(directory: URL) {
            self.directory = directory
        }

        // swiftlint:disable:next function_parameter_count
        func exportMeeting(
            title _: String,
            date _: Date?,
            tags _: [String],
            markdown _: String,
            transcript _: String?,
            existingPageID _: String?,
            onPageCreated _: @Sendable (NotionPageResult) async -> Void,
        ) throws -> NotionPageResult {
            let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            markdownFilesAtExport = files.filter { $0.hasSuffix(".md") }
            return NotionPageResult(pageID: "page-1")
        }
    }

    /// Reference-type collector for state transitions captured via onJobStateChange.
    private final class TransitionCollector {
        var transitions: [(JobState, JobState)] = []
    }

    private func makeHarness(
        diarizeEnabled: Bool = false,
        stagingDir: URL? = nil,
        echoDedupEnabled: Bool = true,
        includeFullTranscriptInProtocol: Bool = true,
        saveRawTranscriptSeparately: Bool = true,
        protocolGeneratorEnabled: Bool = true,
        transcriptOutputOptionsProvider: (() -> TranscriptOutputOptions)? = nil,
        echoCancellationEnabled: Bool = false,
        echoCancellerFactory: (() -> (any EchoCancelling)?)? = nil,
        notionExportConfiguration: NotionExportConfiguration? = nil,
        notionExportResolution: NotionExportResolution? = nil,
    ) throws -> (Harness, TransitionCollector) {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello world"),
            TimestampedSegment(start: 5, end: 10, text: "This is a test"),
        ]

        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                .init(start: 5, end: 10, speaker: "SPEAKER_01"),
            ],
            speakingTimes: ["SPEAKER_00": 5.0, "SPEAKER_01": 5.0],
            autoNames: [:],
            embeddings: ["SPEAKER_00": [1, 0, 0], "SPEAKER_01": [0, 1, 0]],
        )

        let protocolGen = MockProtocolGen()
        let collector = TransitionCollector()
        let exportConfigurationProvider: () -> NotionExportResolution = {
            notionExportResolution ?? notionExportConfiguration.map(NotionExportResolution.ready) ?? .disabled
        }

        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { protocolGeneratorEnabled ? protocolGen : nil },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: stagingDir ?? AppPaths.recordingsDir,
            diarizeEnabled: diarizeEnabled,
            echoDedupEnabled: echoDedupEnabled,
            echoCancellationEnabled: { echoCancellationEnabled },
            echoCancellerFactory: echoCancellerFactory,
            micLabel: "Me",
            includeFullTranscriptInProtocol: includeFullTranscriptInProtocol,
            saveRawTranscriptSeparately: saveRawTranscriptSeparately,
            transcriptOutputOptionsProvider: transcriptOutputOptionsProvider,
            notionExportConfigurationProvider: exportConfigurationProvider,
        )

        queue.onJobStateChange = { [collector] _, old, new in
            collector.transitions.append((old, new))
        }

        let audioPath = try createTestAudioFile(in: tmpDir)

        let harness = Harness(
            queue: queue, engine: engine, diarization: diarization,
            protocolGen: protocolGen, audioPath: audioPath,
        )
        return (harness, collector)
    }

    // swiftlint:disable:next function_default_parameter_at_end
    private func makeJob(title: String = "Test Meeting", audioPath: URL) -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: audioPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }

    private func assertNoRawTranscriptArtifacts(_ h: Harness) {
        XCTAssertNil(h.queue.jobs.first?.transcriptPath)
        let protocolsDir = tmpDir.appendingPathComponent("protocols")
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let protocolFiles = (try? FileManager.default.contentsOfDirectory(atPath: protocolsDir.path)) ?? []
        let recordingFiles = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
        XCTAssertFalse(protocolFiles.contains { $0.hasSuffix(".txt") })
        XCTAssertFalse(recordingFiles.contains { $0.hasSuffix("_segments.json") })
    }

    // swiftlint:disable:next function_default_parameter_at_end
    private func makeDualSourceJob(title: String = "Dual Meeting", audioPath: URL) throws -> PipelineJob {
        let appPath = tmpDir.appendingPathComponent("app_\(UUID().uuidString).wav")
        let micPath = tmpDir.appendingPathComponent("mic_\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: audioPath, to: appPath)
        try FileManager.default.copyItem(at: audioPath, to: micPath)
        return PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: audioPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: 0,
        )
    }

    /// Wait until the (single) job reaches a terminal state. Speaker naming was
    /// converged onto the async production flow: the injected handler now runs
    /// after the job reaches `.speakerNamingPending`, in a detached Task that
    /// outlives `processNext()`. Tests asserting on the final state must wait
    /// for it rather than reading it right after `processNext()` returns.
    private func awaitJobTerminalState(_ queue: PipelineQueue, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = queue.jobs.first?.state, state == .done || state == .error { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Happy Path: Single-Source, No Diarization

    func testWorkflowSingleSourceNoDiarization() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: false)
        let job = makeJob(audioPath: h.audioPath)

        h.queue.enqueue(job)
        await h.queue.processNext()

        // State transitions: waiting → transcribing → generatingProtocol → done
        XCTAssertEqual(
            collector.transitions.map(\.1),
            [.transcribing, .generatingProtocol, .done],
        )

        // Engine was called once, diarization not at all
        XCTAssertEqual(h.engine.transcribeCallCount, 1)
        XCTAssertEqual(h.diarization.runCount, 0)

        // Protocol generator received transcript
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertEqual(h.protocolGen.capturedTitle, "Test Meeting")
        XCTAssertTrue(h.protocolGen.capturedTranscript?.contains("Hello world") ?? false)

        // Job is done with protocol file on disk
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertNotNil(h.queue.jobs.first?.protocolPath)

        if let path = h.queue.jobs.first?.protocolPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        }
    }

    func testWorkflowCanExcludeFullTranscriptFromProtocol() async throws {
        let (h, _) = try makeHarness(includeFullTranscriptInProtocol: false)
        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        await h.queue.processNext()

        let protocolPath = try XCTUnwrap(h.queue.jobs.first?.protocolPath)
        let markdown = try String(contentsOf: protocolPath, encoding: .utf8)
        XCTAssertFalse(markdown.contains("## Full Transcript"))
        XCTAssertFalse(markdown.contains("Hello world"))
        XCTAssertNotNil(h.queue.jobs.first?.transcriptPath)
    }

    func testWorkflowCanRemoveSeparateRawTranscriptAfterCompletion() async throws {
        let (h, _) = try makeHarness(saveRawTranscriptSeparately: false)
        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        await h.queue.processNext()

        let protocolPath = try XCTUnwrap(h.queue.jobs.first?.protocolPath)
        let markdown = try String(contentsOf: protocolPath, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Full Transcript"))
        XCTAssertNil(h.queue.jobs.first?.transcriptPath)
        let protocolsDir = tmpDir.appendingPathComponent("protocols")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: protocolsDir.path)
                .contains { $0.hasSuffix(".txt") },
        )
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)
                .contains { $0.hasSuffix("_segments.json") },
        )
    }

    func testWorkflowRawTranscriptCleanupPreservesRecording() async throws {
        let stagingDir = tmpDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedAudioPath = try createTestAudioFile(in: stagingDir)
        let (h, _) = try makeHarness(stagingDir: stagingDir, saveRawTranscriptSeparately: false)

        h.queue.enqueue(makeJob(audioPath: stagedAudioPath))
        await h.queue.processNext()

        assertNoRawTranscriptArtifacts(h)
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let recordingFiles = try FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)
        XCTAssertTrue(recordingFiles.contains { $0.hasSuffix(".wav") })
    }

    func testWorkflowMinutesOnlyRetainsNoTranscriptArtifacts() async throws {
        let (h, _) = try makeHarness(
            includeFullTranscriptInProtocol: false,
            saveRawTranscriptSeparately: false,
        )
        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        await h.queue.processNext()

        let protocolPath = try XCTUnwrap(h.queue.jobs.first?.protocolPath)
        let markdown = try String(contentsOf: protocolPath, encoding: .utf8)
        XCTAssertFalse(markdown.contains("## Full Transcript"))
        XCTAssertFalse(markdown.contains("Hello world"))
        XCTAssertNil(h.queue.jobs.first?.transcriptPath)

        let protocolsDir = tmpDir.appendingPathComponent("protocols")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: protocolsDir.path)
                .contains { $0.hasSuffix(".txt") },
        )
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)
                .contains { $0.hasSuffix("_segments.json") },
        )
    }

    func testWorkflowCapturesCurrentOutputOptionsWhenJobIsEnqueued() async throws {
        var currentOptions = TranscriptOutputOptions(
            includeFullTranscriptInProtocol: true,
            saveRawTranscriptSeparately: true,
            useAITitleForFilenames: false,
        )
        let (h, _) = try makeHarness { currentOptions }
        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        currentOptions = TranscriptOutputOptions(
            includeFullTranscriptInProtocol: false,
            saveRawTranscriptSeparately: false,
            useAITitleForFilenames: false,
        )
        await h.queue.processNext()

        let protocolPath = try XCTUnwrap(h.queue.jobs.first?.protocolPath)
        let markdown = try String(contentsOf: protocolPath, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Full Transcript"))
        XCTAssertNotNil(h.queue.jobs.first?.transcriptPath)
    }

    // MARK: - Happy Path: Single-Source, Diarization + Speaker Naming

    func testWorkflowWithDiarizationAndNaming() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: true)

        h.queue.speakerNamingHandler = { data in
            // Verify naming data is populated
            XCTAssertFalse(data.mapping.isEmpty)
            XCTAssertFalse(data.speakingTimes.isEmpty)
            return .confirmed(["SPEAKER_00": "Alice", "SPEAKER_01": "Speaker C"])
        }

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue)

        // State transitions: waiting → transcribing → diarizing →
        // speakerNamingPending → generatingProtocol → done. The confirm path
        // re-enters .generatingProtocol (completeSpeakerNaming transitions the
        // pending job, then the transcript-rewrite calls generateProtocol),
        // which fires an identical consecutive state-change. Collapse those
        // before comparing so the assertion pins the stage ORDER, not the
        // production path's internal re-entry.
        let stageOrder = collector.transitions.map(\.1).reduce(into: [JobState]()) { acc, state in
            if acc.last != state { acc.append(state) }
        }
        XCTAssertEqual(
            stageOrder,
            [.transcribing, .diarizing, .speakerNamingPending, .generatingProtocol, .done],
        )

        // Diarization called once, protocol generated
        XCTAssertEqual(h.diarization.runCount, 1)
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    func testWorkflowConfirmedNamingCleansRawOutputWhenDisabled() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true, saveRawTranscriptSeparately: false)
        h.queue.speakerNamingHandler = { _ in
            .confirmed(["SPEAKER_00": "Alice", "SPEAKER_01": "Speaker C"])
        }

        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue)

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        assertNoRawTranscriptArtifacts(h)
    }

    func testWorkflowSkippedNamingCleansRawOutputWhenDisabled() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true, saveRawTranscriptSeparately: false)
        h.queue.speakerNamingHandler = { _ in .skipped }

        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue)

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        assertNoRawTranscriptArtifacts(h)
    }

    // MARK: - Happy Path: Dual-Source

    func testWorkflowDualSource() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: false)
        let job = try makeDualSourceJob(audioPath: h.audioPath)

        h.queue.enqueue(job)
        await h.queue.processNext()

        // Engine called twice (app + mic tracks)
        XCTAssertEqual(h.engine.transcribeCallCount, 2)

        // Protocol generated with merged transcript containing "Remote" label
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertTrue(
            h.protocolGen.capturedTranscript?.contains("Remote") ?? false,
            "Dual-source transcript should contain 'Remote' speaker label",
        )

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    // MARK: - Paired Import Regression

    /// Reproduces the bug behind the "feat: paired import" PR's first iteration.
    /// When the picker selected only `_app.wav` + `_mic.wav` (no `_mix.wav`), the
    /// constructed job had `mixPath == appPath`. `persistAudioToOutput`'s first
    /// move renamed the source to `<slug>_mix.wav`; the second move silently
    /// failed; `recoverOrphanedRecordings` re-picked the renamed file on every
    /// launch, producing an endless compounding-rename chain on disk.
    ///
    /// This test runs the full mock pipeline through a paired triplet
    /// (`_app + _mic + _mix`) and asserts the output dir contains a clean
    /// triplet — no `<slug>_app_mix.wav`, `<slug>_mic_mix.wav`, or similar
    /// aliasing artifacts.
    func testWorkflowPairedImportTripletProducesCleanOutputTriplet() async throws {
        // The triplet has to count as audio the app produced, otherwise the move
        // loop never runs and the aliasing artifacts this test looks for cannot
        // appear no matter how broken the code is.
        let importDir = try makeTempDirectory(prefix: "import-source")
        let (h, _) = try makeHarness(diarizeEnabled: false, stagingDir: importDir)
        let mixURL = importDir.appendingPathComponent("standup_mix.wav")
        let appURL = importDir.appendingPathComponent("standup_app.wav")
        let micURL = importDir.appendingPathComponent("standup_mic.wav")
        for url in [mixURL, appURL, micURL] {
            try FileManager.default.copyItem(at: h.audioPath, to: url)
        }

        let resolution = PairedRecordingResolver.resolve(urls: [mixURL, appURL, micURL])
        XCTAssertEqual(resolution.paired.count, 1)
        let group = try XCTUnwrap(resolution.paired.first)
        XCTAssertNotEqual(group.mix, group.app, "regression: mixPath must not alias appPath")
        XCTAssertNotEqual(group.mix, group.mic, "regression: mixPath must not alias micPath")

        let job = try PipelineJob(
            meetingTitle: group.stem,
            appName: "File",
            mixPath: XCTUnwrap(group.mix),
            appPath: group.app,
            micPath: group.mic,
            micDelay: 0,
        )
        h.queue.enqueue(job)
        await h.queue.processNext()

        XCTAssertEqual(h.queue.jobs.first?.state, .done)

        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
        let audioWAVs = names.filter { $0.hasSuffix(".wav") && !$0.contains("_16k") }

        // Exactly one triplet — no aliasing artifacts.
        XCTAssertEqual(audioWAVs.count { $0.hasSuffix(RecordingFileSuffix.mix) }, 1)
        XCTAssertEqual(audioWAVs.count { $0.hasSuffix(RecordingFileSuffix.app) }, 1)
        XCTAssertEqual(audioWAVs.count { $0.hasSuffix(RecordingFileSuffix.mic) }, 1)
        for name in audioWAVs {
            XCTAssertFalse(
                name.contains("_app_mix.wav") || name.contains("_mic_mix.wav"),
                "Aliasing artifact in output filename: \(name)",
            )
        }
    }

    /// app+mic without an on-disk `_mix.wav` (`mixPath: nil`) runs the dual-track
    /// pipeline without writing any persistent mix file to the recordings dir.
    /// The pipeline mixes app+mic into the workdir cache on the fly.
    func testWorkflowAppPlusMicWithNilMixPathProducesTranscriptOnly() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        h.queue.speakerNamingHandler = { _ in .skipped }

        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let appURL = recordingsDir.appendingPathComponent("meeting_app.wav")
        let micURL = recordingsDir.appendingPathComponent("meeting_mic.wav")
        try FileManager.default.copyItem(at: h.audioPath, to: appURL)
        try FileManager.default.copyItem(at: h.audioPath, to: micURL)

        let job = PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil, appPath: appURL, micPath: micURL,
            micDelay: 0,
        )
        h.queue.enqueue(job)
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue)

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path), "user app source preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "user mic source preserved")

        // No `<slug>_mix.wav` artefact in the recordings dir — only the
        // user's app + mic sources + 16k caches.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
        let extraneousMixes = names.filter { name in
            name.hasSuffix(RecordingFileSuffix.mix) && name != "meeting_mix.wav"
        }
        XCTAssertTrue(
            extraneousMixes.isEmpty,
            "no slug-renamed mix should be written; got: \(extraneousMixes)",
        )
    }

    /// Re-importing a recording from `outputDir/recordings/` used to rename the
    /// source file in place with a fresh `<today_timestamp>_<title>` prefix,
    /// and `recoverOrphanedRecordings` would re-pick the new name on the next
    /// launch — endless compounding-rename loop on disk. Fix: skip the move
    /// when the source already lives in the target directory.
    func testWorkflowSourceFilesInOutputDirAreNotRenamed() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: false)

        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let mixURL = recordingsDir.appendingPathComponent("standup_mix.wav")
        let appURL = recordingsDir.appendingPathComponent("standup_app.wav")
        let micURL = recordingsDir.appendingPathComponent("standup_mic.wav")
        for url in [mixURL, appURL, micURL] {
            try FileManager.default.copyItem(at: h.audioPath, to: url)
        }

        let job = PipelineJob(
            meetingTitle: "standup",
            appName: "File",
            mixPath: mixURL,
            appPath: appURL,
            micPath: micURL,
            micDelay: 0,
        )
        h.queue.enqueue(job)
        await h.queue.processNext()

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixURL.path), "mix source preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path), "app source preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "mic source preserved")

        // No prefixed copies — original filenames untouched.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
        let extraMixes = names.filter { $0.hasSuffix("_mix.wav") && $0 != "standup_mix.wav" }
        XCTAssertTrue(extraMixes.isEmpty, "no prefixed _mix.wav copies, found: \(extraMixes)")
    }

    // MARK: - Error Scenarios

    func testWorkflowEmptyTranscriptEndsInError() async throws {
        let (h, collector) = try makeHarness()
        h.engine.segmentsToReturn = [] // no speech

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // State: waiting → transcribing → error
        XCTAssertEqual(collector.transitions.map(\.1), [.transcribing, .error])
        XCTAssertEqual(h.queue.jobs.first?.state, .error)
        XCTAssertEqual(h.queue.jobs.first?.error, "Empty transcript")

        // Protocol was NOT generated
        XCTAssertFalse(h.protocolGen.generateCalled)
    }

    func testWorkflowEngineThrowsEndsInError() async throws {
        let (h, _) = try makeHarness()
        h.engine.shouldThrow = true

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Job ends in error
        XCTAssertEqual(h.queue.jobs.first?.state, .error)
        XCTAssertFalse(h.protocolGen.generateCalled)
    }

    func testWorkflowProtocolGenerationFailsSavesTranscriptWithWarning() async throws {
        let (h, _) = try makeHarness()
        h.protocolGen.shouldThrow = true

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Job completes with warning (graceful fallback), transcript saved
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertNotNil(h.queue.jobs.first?.transcriptPath)
        XCTAssertNil(h.queue.jobs.first?.protocolPath)
        XCTAssertFalse(h.queue.jobs.first?.warnings.isEmpty ?? true)
    }

    func testWorkflowProtocolFailureRetainsRawOutputWhenDisabled() async throws {
        let (h, _) = try makeHarness(saveRawTranscriptSeparately: false)
        h.protocolGen.shouldThrow = true

        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        await h.queue.processNext()

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertNotNil(h.queue.jobs.first?.transcriptPath)
        XCTAssertTrue(h.queue.jobs.first?.warnings.contains("Raw transcript retained because no protocol was saved") ?? false)
    }

    func testWorkflowWithoutProtocolGeneratorRetainsRawOutputWhenDisabled() async throws {
        let (h, _) = try makeHarness(
            saveRawTranscriptSeparately: false,
            protocolGeneratorEnabled: false,
        )

        h.queue.enqueue(makeJob(audioPath: h.audioPath))
        await h.queue.processNext()

        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertNil(h.queue.jobs.first?.protocolPath)
        XCTAssertNotNil(h.queue.jobs.first?.transcriptPath)
        XCTAssertTrue(h.queue.jobs.first?.warnings.contains("Raw transcript retained because no protocol was saved") ?? false)
    }

    // MARK: - Diarization Scenarios

    func testWorkflowDiarizationUnavailableSkips() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: true)
        h.diarization.isAvailable = false

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should skip diarization — no .diarizing state, but protocol still generated
        let states = collector.transitions.map(\.1)
        XCTAssertFalse(states.contains(.diarizing))
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    /// Regression: dual-source recording where the mic track produces no
    /// detectable speakers (silent BlackHole input on a mic-less Mac mini,
    /// noisy office without anyone speaking close to the mic, etc.).
    /// The mic-track diarizer throws; the pipeline must fall back to
    /// app-only diarization, complete with `.done`, save the transcript,
    /// and warn with the new "Mic track diarization failed" message —
    /// not the old all-or-nothing "speakers not identified".
    func testWorkflowDualSourceMicDiarizationFailsFallsBackToAppOnly() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        h.diarization.throwOnPathSuffix = "mic_16k.wav"
        h.queue.speakerNamingHandler = { _ in .skipped }

        let job = try makeDualSourceJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue)

        let finalJob = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(finalJob.state, .done, "Pipeline must complete when only mic diarization fails")
        XCTAssertNotNil(finalJob.transcriptPath)

        let warnings = finalJob.warnings.joined(separator: " | ")
        XCTAssertTrue(
            warnings.contains("Mic track diarization failed"),
            "Expected the new fallback warning, got: \(warnings)",
        )
        XCTAssertFalse(
            warnings.contains("speakers not identified"),
            "The old all-or-nothing warning should not fire for the mic-only fallback path",
        )
    }

    func testWorkflowDiarizationNoEmbeddingsFallsBack() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        h.diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 5],
            autoNames: [:],
            embeddings: nil, // no embeddings → naming loop breaks early
        )

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should complete despite no embeddings
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(h.protocolGen.generateCalled)
    }

    // MARK: - Speaker Naming Scenarios

    func testWorkflowSpeakerNamingSkipped() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        h.queue.speakerNamingHandler = { _ in .skipped }

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue)

        // Still completes even when naming is skipped
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(h.protocolGen.generateCalled)
    }

    func testWorkflowSpeakerNamingRerun() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)

        var callCount = 0
        h.queue.speakerNamingHandler = { _ in
            callCount += 1
            return callCount == 1 ? .rerun(3) : .confirmed(["SPEAKER_00": "Alice"])
        }

        let job = makeJob(audioPath: h.audioPath)
        h.queue.enqueue(job)
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue, timeout: 30)

        // Handler called twice (first rerun, then confirm), diarization ran twice.
        // The rerun now routes through the late-diarization path
        // (completeSpeakerNaming → lateDiarization), which re-diarizes once more.
        XCTAssertEqual(callCount, 2)
        XCTAssertGreaterThanOrEqual(h.diarization.runCount, 2)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
    }

    // MARK: - Multi-Job

    func testMultipleJobsProcessedSequentially() async throws {
        let (h, _) = try makeHarness()

        // Enqueue and process first job
        let job1 = makeJob(title: "Meeting 1", audioPath: h.audioPath)
        h.queue.enqueue(job1)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first { $0.id == job1.id }?.state, .done)

        // Enqueue and process second job
        let audio2 = try createTestAudioFile(in: tmpDir)
        let job2 = makeJob(title: "Meeting 2", audioPath: audio2)
        h.queue.enqueue(job2)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first { $0.id == job2.id }?.state, .done)

        // Engine called twice total (once per job)
        XCTAssertEqual(h.engine.transcribeCallCount, 2)
    }

    func testErrorJobDoesNotBlockNextJob() async throws {
        let (h, _) = try makeHarness()

        // First job will fail (empty transcript)
        let audio1 = try createTestAudioFile(in: tmpDir)
        let job1 = makeJob(title: "Silent", audioPath: audio1)
        h.engine.segmentsToReturn = []
        h.queue.enqueue(job1)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first?.state, .error)

        // Second job should succeed
        h.engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Now it works"),
        ]
        let audio2 = try createTestAudioFile(in: tmpDir)
        let job2 = makeJob(title: "Working", audioPath: audio2)
        h.queue.enqueue(job2)
        await h.queue.processNext()
        XCTAssertEqual(h.queue.jobs.first { $0.id == job2.id }?.state, .done)
    }

    // MARK: - Single-Source Fallback (App-Only / Mic-Only)

    func testWorkflowAppOnlyNoMic() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: false)
        let appPath = tmpDir.appendingPathComponent("app_\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: h.audioPath, to: appPath)

        let job = PipelineJob(
            meetingTitle: "App Only Meeting",
            appName: "Microsoft Teams",
            mixPath: h.audioPath,
            appPath: appPath,
            micPath: nil,
            micDelay: 0,
        )

        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should complete as single-source (app track only)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(collector.transitions.map(\.1).contains(.done))

        // Engine called once (single-source fallback)
        XCTAssertEqual(h.engine.transcribeCallCount, 1)

        // Protocol generated
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertNotNil(h.queue.jobs.first?.protocolPath)
    }

    func testWorkflowMicOnlyNoApp() async throws {
        let (h, collector) = try makeHarness(diarizeEnabled: false)
        let micPath = tmpDir.appendingPathComponent("mic_\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: h.audioPath, to: micPath)

        let job = PipelineJob(
            meetingTitle: "Mic Only Meeting",
            appName: "Microsoft Teams",
            mixPath: h.audioPath,
            appPath: nil,
            micPath: micPath,
            micDelay: 0,
        )

        h.queue.enqueue(job)
        await h.queue.processNext()

        // Should complete as single-source (mic track only)
        XCTAssertEqual(h.queue.jobs.first?.state, .done)
        XCTAssertTrue(collector.transitions.map(\.1).contains(.done))

        // Engine called once (single-source fallback)
        XCTAssertEqual(h.engine.transcribeCallCount, 1)

        // Protocol generated
        XCTAssertTrue(h.protocolGen.generateCalled)
        XCTAssertNotNil(h.queue.jobs.first?.protocolPath)
    }

    // MARK: - None LLM Provider (Transcript Only)

    func testWorkflowNoneProviderSavesTranscriptOnly() async throws {
        let engine = MockEngine()
        engine.segmentsToReturn = [
            TimestampedSegment(start: 0, end: 5, text: "Hello world"),
        ]
        let collector = TransitionCollector()

        // Factory returns nil → no protocol generation
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: tmpDir,
            logDir: tmpDir,
        )
        queue.onJobStateChange = { [collector] _, old, new in
            collector.transitions.append((old, new))
        }

        let audioPath = try createTestAudioFile(in: tmpDir)
        let job = makeJob(title: "Transcript Only", audioPath: audioPath)
        queue.enqueue(job)
        await queue.processNext()

        // Job completes without .generatingProtocol state
        let states = collector.transitions.map(\.1)
        XCTAssertFalse(states.contains(.generatingProtocol))
        XCTAssertEqual(queue.jobs.first?.state, .done)

        // Transcript saved, no protocol
        XCTAssertNotNil(queue.jobs.first?.transcriptPath)
        XCTAssertNil(queue.jobs.first?.protocolPath)

        // No warnings (this is intentional, not a failure)
        XCTAssertTrue(queue.jobs.first?.warnings.isEmpty ?? false)
    }

    // MARK: - Notion export

    func testWorkflowRecordsTheNotionPageOnceTheExportFinishes() async throws {
        let exporter = StubNotionExporter(
            result: NotionPageResult(
                pageID: "page-1",
                url: "https://www.notion.so/page-1",
                omittedProperties: ["Date"],
            ),
        )
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
        )

        let job = makeJob(title: "Notion Export", audioPath: harness.audioPath)
        harness.queue.enqueue(job)
        await harness.queue.processNext()
        await harness.queue.awaitNotionExports()

        let finished = try XCTUnwrap(harness.queue.jobs.first)
        XCTAssertEqual(finished.state, .done)
        XCTAssertEqual(finished.notionPageID, "page-1")
        XCTAssertEqual(finished.notionDatabaseID, "database-1")
        XCTAssertEqual(finished.notionPageURL?.absoluteString, "https://www.notion.so/page-1")
        XCTAssertTrue(finished.warnings.contains { $0.contains("omitted Date") })
        XCTAssertNotNil(finished.protocolPath, "A successful export keeps local Markdown by default")
        let exports = await exporter.exports
        XCTAssertEqual(exports.first?.tags, [], "No speaker or fixed tags are exported by default")
    }

    func testDirectDiarizationExportsStructuredSpeakerTagsWithoutNamingDialog() async throws {
        for headless in [false, true] {
            let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1"))
            let (harness, _) = try makeHarness(
                diarizeEnabled: true,
                notionExportConfiguration: NotionExportConfiguration(
                    exporter: exporter, databaseID: "database-1", speakerTagsEnabled: true,
                ),
            )
            harness.diarization.resultToReturn = DiarizationResult(
                segments: [
                    .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                    .init(start: 5, end: 10, speaker: "SPEAKER_01"),
                ],
                speakingTimes: ["SPEAKER_00": 6, "SPEAKER_01": 4],
                autoNames: ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"],
                embeddings: headless ? ["SPEAKER_00": [1, 0, 0], "SPEAKER_01": [0, 1, 0]] : nil,
            )
            let job = PipelineJob(
                meetingTitle: "Direct Export", appName: "File", mixPath: harness.audioPath,
                appPath: nil, micPath: nil, micDelay: 0,
                participants: ["Alice", "Bob"], autoSkipNaming: headless,
            )
            harness.queue.enqueue(job)
            await harness.queue.awaitProcessing()

            let exports = await exporter.exports
            let exported = try XCTUnwrap(exports.first)
            XCTAssertEqual(exported.tags.sorted(), ["Alice", "Bob"])
            XCTAssertEqual(harness.queue.jobs.first?.state, .done)
            XCTAssertNil(harness.queue.speakerNamingDataByJob[job.id])
        }
    }

    func testEnabledButUnconfiguredExportWarnsAndKeepsLocalProtocol() async throws {
        let (harness, _) = try makeHarness(notionExportResolution: .unconfigured)
        harness.queue.enqueue(makeJob(audioPath: harness.audioPath))
        await harness.queue.awaitProcessing()

        let finished = try XCTUnwrap(harness.queue.jobs.first)
        XCTAssertTrue(finished.warnings.contains(PipelineQueue.notionExportUnconfiguredWarning))
        XCTAssertNotNil(finished.protocolPath)
        XCTAssertNil(finished.notionExportStatus)
    }

    func testDisabledExportAddsNoWarning() async throws {
        let (harness, _) = try makeHarness(notionExportResolution: .disabled)
        harness.queue.enqueue(makeJob(audioPath: harness.audioPath))
        await harness.queue.awaitProcessing()

        XCTAssertFalse(try XCTUnwrap(harness.queue.jobs.first).warnings.contains(PipelineQueue.notionExportUnconfiguredWarning))
    }

    func testSuccessfulNotionOnlyExportCountsAsASavedProtocol() async throws {
        let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"))
        let (harness, _) = try makeHarness(
            saveRawTranscriptSeparately: false,
            notionExportConfiguration: NotionExportConfiguration(
                exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
            ),
        )
        harness.queue.enqueue(makeJob(audioPath: harness.audioPath))
        await harness.queue.awaitProcessing()

        let finished = try XCTUnwrap(harness.queue.jobs.first)
        XCTAssertNil(finished.protocolPath)
        XCTAssertFalse(finished.warnings.contains { $0.contains("Raw transcript retained") })
        XCTAssertNil(finished.transcriptPath)
    }

    func testFailedExportKeepsLocalProtocolAndNamesTheReason() async throws {
        let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1"), fail: true)
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
        )
        harness.queue.enqueue(makeJob(audioPath: harness.audioPath))
        await harness.queue.awaitProcessing()

        let finished = try XCTUnwrap(harness.queue.jobs.first)
        XCTAssertNotNil(finished.protocolPath)
        XCTAssertEqual(finished.notionExportStatus, .failed)
        XCTAssertEqual(finished.warnings.filter { $0.hasPrefix("Notion export failed (") }.count, 1)
    }

    func testSlowExportDoesNotHoldUpTheJobOrTheQueue() async throws {
        let exporter = GatedNotionExporter()
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
        )
        harness.queue.enqueue(makeJob(audioPath: harness.audioPath))
        await harness.queue.processNext()

        let running = try XCTUnwrap(harness.queue.jobs.first)
        XCTAssertEqual(running.state, .done)
        XCTAssertEqual(running.notionExportStatus, .inProgress)
        XCTAssertFalse(harness.queue.isProcessing)

        await exporter.release()
        await harness.queue.awaitNotionExports()
        XCTAssertEqual(harness.queue.jobs.first?.notionExportStatus, .completed)
    }

    func testNotionOnlyExportRemovesItsBackupOnlyAfterSucceeding() async throws {
        let exporter = GatedNotionExporter()
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(
                exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
            ),
        )
        harness.queue.enqueue(makeJob(audioPath: harness.audioPath))
        await harness.queue.processNext()

        let backup = try XCTUnwrap(harness.queue.jobs.first?.protocolPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        await exporter.release()
        await harness.queue.awaitNotionExports()
        XCTAssertNil(harness.queue.jobs.first?.protocolPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testEveryFinishedExportReportsItsOutcome() async throws {
        for (fail, reason) in [(false, nil), (true, "network error")] as [(Bool, String?)] {
            let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1"), fail: fail)
            let (harness, _) = try makeHarness(
                notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
            )
            var outcomes: [String?] = []
            harness.queue.onNotionExportFinished = { _, failure in outcomes.append(failure) }
            let job = makeJob(audioPath: harness.audioPath)
            harness.queue.enqueue(job)
            await harness.queue.awaitProcessing()
            XCTAssertEqual(outcomes, [reason])

            if fail {
                await harness.queue.retryNotionExport(id: job.id)
                XCTAssertEqual(outcomes, [reason, reason], "a retry reports too")
            }
        }
    }

    func testAcceptingAutoNamesExportsOnlyRealNamesAsTags() async throws {
        let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1"))
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(
                exporter: exporter, databaseID: "database-1", speakerTagsEnabled: true,
            ),
        )
        let transcriptPath = tmpDir.appendingPathComponent("meeting.txt")
        try "[00:00] Alice: Hello".write(to: transcriptPath, atomically: true, encoding: .utf8)
        var job = makeJob(audioPath: harness.audioPath)
        job.state = .speakerNamingPending
        job.transcriptPath = transcriptPath
        harness.queue.insertJobForTesting(job)
        harness.queue.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(
            jobID: job.id, mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": "SPEAKER_1"],
        )

        harness.queue.completeSpeakerNaming(jobID: job.id, result: .skipped)
        for _ in 0 ..< 200 where await exporter.exports.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await harness.queue.awaitNotionExports()

        let exports = await exporter.exports
        XCTAssertEqual(exports.first?.tags, ["Alice"])
    }

    func testGenericSpeakerLabelsAreNotExportedAsTags() {
        XCTAssertEqual(
            NotionTagFilter.confirmedNames(["Alice", "SPEAKER_00", "R_SPEAKER_1", "M_SPEAKER_2", "Speaker 3", "Smith, John"]),
            ["Alice", "Smith, John"],
        )
    }

    func testOnlyNotionHttpsURLsAreStoredOnTheJob() {
        for good in ["https://app.notion.com/p/a", "https://www.notion.so/a", "https://team.notion.site/a"] {
            XCTAssertNotNil(PipelineJob.trustedNotionURL(good), good)
        }
        for bad in ["http://www.notion.so/a", "https://evilnotion.so/a", "https://notion.so.evil.com/a", "file:///etc/passwd"] {
            XCTAssertNil(PipelineJob.trustedNotionURL(bad), bad)
        }
    }

    func testLocalProtocolIsOnDiskBeforeTheExportStarts() async throws {
        let exporter = LocalFileObservingExporter(directory: tmpDir)
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
        )
        harness.queue.enqueue(makeJob(audioPath: harness.audioPath))
        await harness.queue.awaitProcessing()

        let files = await exporter.markdownFilesAtExport
        XCTAssertEqual(files.count, 1)
    }

    func testHeldFailedExportReleasesItsAudioSidecars() async throws {
        let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1"), fail: true)
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
        )
        let job = makeJob(audioPath: harness.audioPath)
        let store = SpeakerNamingStore(outputDir: tmpDir)
        let recordings = try XCTUnwrap(tmpDir).appendingPathComponent("recordings")
        var slug: String?
        harness.protocolGen.onGenerate = { [queue = harness.queue] in
            slug = queue.jobs.first { $0.id == job.id }?.namingSlug
            guard let slug else { return }
            try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: recordings.appendingPathComponent("\(slug)_16k.wav").path, contents: Data([0]))
        }
        harness.queue.enqueue(job)
        await harness.queue.awaitProcessing()

        XCTAssertEqual(harness.queue.jobs.first?.notionExportStatus, .failed)
        let observedSlug = try XCTUnwrap(slug)
        XCTAssertFalse(store.hasSidecar(slug: observedSlug, suffix: SpeakerNamingStore.mixSuffix))
    }

    func testFailedNotionOnlyExportStillSavesLocalBackup() async throws {
        let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1"), fail: true)
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(
                exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
            ),
        )
        let job = makeJob(audioPath: harness.audioPath)
        harness.queue.enqueue(job)
        await harness.queue.awaitProcessing()

        let finished = try XCTUnwrap(harness.queue.jobs.first)
        let backup = try XCTUnwrap(finished.protocolPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(finished.warnings.contains { $0.contains("Notion export failed") })
    }

    func testPartialNotionExportRetriesSavedMarkdownWithoutReprocessingAudio() async throws {
        let exporter = StubNotionExporter(
            result: NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            failAfterPageCreatedCount: 1,
        )
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(
                exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
            ),
        )
        var generationCount = 0
        harness.protocolGen.onGenerate = { generationCount += 1 }
        let job = makeJob(audioPath: harness.audioPath)
        harness.queue.enqueue(job)
        await harness.queue.awaitProcessing()

        let failed = try XCTUnwrap(harness.queue.jobs.first)
        XCTAssertEqual(failed.state, .done)
        XCTAssertEqual(failed.notionExportStatus, .failed)
        XCTAssertEqual(failed.notionPageID, "page-1")
        let backup = try XCTUnwrap(failed.protocolPath)
        let savedMarkdown = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(savedMarkdown.contains("## Full Transcript"))
        XCTAssertTrue(savedMarkdown.contains("Hello world"))
        XCTAssertTrue(harness.queue.canRetryNotionExport(id: job.id))
        XCTAssertEqual(harness.engine.transcribeCallCount, 1)
        XCTAssertEqual(generationCount, 1)

        let retrySucceeded = await harness.queue.retryNotionExport(id: job.id)
        XCTAssertTrue(retrySucceeded)

        let exports = await exporter.exports
        XCTAssertEqual(exports.count, 2)
        XCTAssertEqual(exports[1].existingPageID, "page-1")
        XCTAssertEqual(exports[1].markdown, savedMarkdown)
        XCTAssertNil(exports[1].transcript, "The transcript is already embedded in the saved Markdown")
        XCTAssertEqual(harness.engine.transcribeCallCount, 1)
        XCTAssertEqual(generationCount, 1)
        XCTAssertEqual(harness.queue.jobs.first?.notionExportStatus, .completed)
        XCTAssertFalse(harness.queue.jobs.first?.warnings.contains { $0.contains("Notion export failed") } ?? true)
        XCTAssertNil(harness.queue.jobs.first?.protocolPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    /// The menu offers the retry from the job's state alone, so a backup removed
    /// behind the app's back is only discovered when the retry runs. It then
    /// says so instead of doing nothing, and does not export an empty page.
    func testNotionRetryReportsAReadFailureWhenTheBackupWasRemovedBehindTheApp() async throws {
        let exporter = StubNotionExporter(
            result: NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            failAfterPageCreatedCount: 1,
        )
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
        )
        let job = makeJob(audioPath: harness.audioPath)
        harness.queue.enqueue(job)
        await harness.queue.awaitProcessing()
        let backup = try XCTUnwrap(harness.queue.jobs.first?.protocolPath)
        try FileManager.default.removeItem(at: backup)

        XCTAssertTrue(harness.queue.canRetryNotionExport(id: job.id), "The hint comes from the job's state, not the file")
        let retrySucceeded = await harness.queue.retryNotionExport(id: job.id)

        XCTAssertFalse(retrySucceeded)
        let failed = try XCTUnwrap(harness.queue.jobs.first)
        XCTAssertEqual(failed.notionExportStatus, .failed)
        XCTAssertTrue(failed.warnings.contains("Could not read the local protocol backup; Notion export was not retried"))
        let exports = await exporter.exports
        XCTAssertEqual(exports.count, 1, "No second export without a backup to export")
    }

    func testSuccessfulNotionRetryKeepsLocalProtocolWithoutSkipLocal() async throws {
        let exporter = StubNotionExporter(
            result: NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            failAfterPageCreatedCount: 1,
        )
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
        )
        let job = makeJob(audioPath: harness.audioPath)
        harness.queue.enqueue(job)
        await harness.queue.awaitProcessing()
        let backup = try XCTUnwrap(harness.queue.jobs.first?.protocolPath)

        let retrySucceeded = await harness.queue.retryNotionExport(id: job.id)

        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(harness.queue.jobs.first?.protocolPath, backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testNotionRetryReusesPageForEquivalentDatabaseIDFormats() async {
        let databaseID = "12345678-1234-1234-1234-123456789abc"
        let exporter = StubNotionExporter(
            result: NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
        )
        let queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Equivalent Database", appName: "File", mixPath: nil,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: databaseID,
        )
        queue.insertJobForTesting(job)
        let configuration = NotionExportConfiguration(
            exporter: exporter, databaseID: databaseID.replacingOccurrences(of: "-", with: "").uppercased(),
        )

        let succeeded = await queue.exportToNotion(
            jobID: job.id, protocolMD: "# Meeting", transcript: nil,
            speakerNames: [], configuration: configuration,
        )

        XCTAssertTrue(succeeded)
        let exports = await exporter.exports
        XCTAssertEqual(exports.first?.existingPageID, "page-1")
    }

    func testFailedNotionExportRestoresAsRetryableWithoutAudio() async throws {
        let exporter = StubNotionExporter(
            result: NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            failAfterPageCreatedCount: 1,
        )
        let configuration = NotionExportConfiguration(
            exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
        )
        let (harness, _) = try makeHarness(notionExportConfiguration: configuration)
        let job = makeJob(audioPath: harness.audioPath)
        harness.queue.enqueue(job)
        await harness.queue.awaitProcessing()
        await harness.queue.awaitSnapshotFlush()
        try FileManager.default.removeItem(at: harness.audioPath)

        let (restoredHarness, _) = try makeHarness(notionExportConfiguration: configuration)
        restoredHarness.queue.loadSnapshot()

        let restored = try XCTUnwrap(restoredHarness.queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(restored.notionExportStatus, .failed)
        XCTAssertTrue(restoredHarness.queue.canRetryNotionExport(id: job.id))
        let retrySucceeded = await restoredHarness.queue.retryNotionExport(id: job.id)
        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(restoredHarness.queue.jobs.first { $0.id == job.id }?.notionExportStatus, .completed)
        XCTAssertEqual(restoredHarness.engine.transcribeCallCount, 0)
        XCTAssertFalse(restoredHarness.protocolGen.generateCalled)
    }

    func testInterruptedNotionExportRestoresAsFailedWithoutAudio() async throws {
        let exporter = StubNotionExporter(
            result: NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            failAfterPageCreatedCount: 1,
        )
        let configuration = NotionExportConfiguration(
            exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
        )
        let (harness, _) = try makeHarness(notionExportConfiguration: configuration)
        let job = makeJob(audioPath: harness.audioPath)
        harness.queue.enqueue(job)
        await harness.queue.awaitProcessing()
        harness.queue.jobs[0].beginNotionExport(speakerNames: [])
        harness.queue.saveSnapshot()
        await harness.queue.awaitSnapshotFlush()
        try FileManager.default.removeItem(at: harness.audioPath)

        let (restoredHarness, _) = try makeHarness(notionExportConfiguration: configuration)
        restoredHarness.queue.loadSnapshot()

        let restored = try XCTUnwrap(restoredHarness.queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(restored.notionExportStatus, .failed)
        XCTAssertEqual(
            restored.warnings.filter { $0.hasPrefix("Notion export failed") },
            ["Notion export failed (interrupted when the app quit); saved locally as backup"],
        )
        XCTAssertTrue(restoredHarness.queue.canRetryNotionExport(id: job.id))
        XCTAssertEqual(restoredHarness.engine.transcribeCallCount, 0)
        XCTAssertFalse(restoredHarness.protocolGen.generateCalled)
    }

    func testInterruptedNotionExportWithoutBackupDoesNotClaimOne() async throws {
        let configuration = NotionExportConfiguration(
            exporter: StubNotionExporter(result: NotionPageResult(pageID: "page-1")), databaseID: "database-1",
        )
        let (harness, _) = try makeHarness(notionExportConfiguration: configuration)
        var job = makeJob(audioPath: harness.audioPath)
        job.state = .done
        job.beginNotionExport(speakerNames: [])
        harness.queue.insertJobForTesting(job)
        harness.queue.saveSnapshot()
        await harness.queue.awaitSnapshotFlush()

        let (restoredHarness, _) = try makeHarness(notionExportConfiguration: configuration)
        restoredHarness.queue.loadSnapshot()

        let restored = try XCTUnwrap(restoredHarness.queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(
            restored.warnings.filter { $0.hasPrefix("Notion export failed") },
            ["Notion export failed (interrupted when the app quit); local backup could not be saved"],
        )
    }

    func testLateSpeakerConfirmationExportsCorrectedTranscriptToExistingPage() async throws {
        let exporter = StubNotionExporter(result: NotionPageResult(pageID: "page-1"))
        let (harness, _) = try makeHarness(
            notionExportConfiguration: NotionExportConfiguration(
                exporter: exporter, databaseID: "database-1",
                skipLocalMarkdown: true, speakerTagsEnabled: true,
            ),
        )
        let transcriptPath = tmpDir.appendingPathComponent("meeting.txt")
        try "[00:00] SPEAKER_0: Hello".write(to: transcriptPath, atomically: true, encoding: .utf8)
        var job = makeJob(audioPath: harness.audioPath)
        job.state = .speakerNamingPending
        job.transcriptPath = transcriptPath
        job.recordNotionPage(NotionPageResult(pageID: "page-1"), databaseID: "database-1")
        harness.queue.insertJobForTesting(job)
        harness.queue.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)

        await harness.queue.naming.reapplySpeakerNames(jobID: job.id, mapping: ["SPEAKER_0": "Smith, John"])
        await harness.queue.awaitNotionExports()

        let exports = await exporter.exports
        let exported = try XCTUnwrap(exports.first)
        XCTAssertEqual(exported.existingPageID, "page-1")
        XCTAssertEqual(exported.transcript, "[00:00] Smith, John: Hello")
        XCTAssertEqual(exported.tags, ["Smith, John"], "Use structured names supplied by speaker confirmation")
        XCTAssertNil(harness.queue.jobs.first?.protocolPath, "Explicit opt-out skips a successful local save")
        XCTAssertEqual(harness.queue.jobs.first?.state, .done)
    }

    // MARK: - Echo bleed warning

    /// The shared aperiodic generator, deliberately not a local copy: an
    /// earlier sine-enveloped one here made two talkers at different syllable
    /// rates nearly orthogonal, so the negative case certified a margin real
    /// recordings do not have.
    private func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        EchoTestAudio.speechLike(seconds: seconds, seed: seed)
    }

    private func writeTrack(_ samples: [Float], to url: URL) throws {
        try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
    }

    private func runDualSource(_ h: Harness, app: URL, mic: URL) async {
        h.queue.speakerNamingHandler = { _ in .skipped }
        h.queue.enqueue(PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil, appPath: app, micPath: mic,
            micDelay: 0,
        ))
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue)
    }

    /// The whole point of the feature: a recording made over loudspeakers says so.
    /// Asserted through the real pipeline, not just the detector, because the
    /// warning reaching the job is the behaviour users get.
    func testDualSourceWithLoudspeakerBleedWarnsOnTheJob() async throws {
        let (h, _) = try makeHarness()
        let recordings = tmpDir.appendingPathComponent("bleed")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

        let far = speechLike(seconds: 40, seed: 11)
        let appURL = recordings.appendingPathComponent("meeting_app.wav")
        let micURL = recordings.appendingPathComponent("meeting_mic.wav")
        try writeTrack(far, to: appURL)
        try writeTrack(EchoTestAudio.bleed(far, delayMs: 15, gain: 0.5), to: micURL)

        await runDualSource(h, app: appURL, mic: micURL)

        XCTAssertEqual(
            h.queue.jobs.first?.echo?.detected, true,
            "the structured verdict is what a driver reads; assert it, not only the sentence",
        )
        let warnings = (h.queue.jobs.first?.warnings ?? []).joined(separator: " | ")
        XCTAssertTrue(
            warnings.contains("picked up by the microphone"),
            "expected an echo-bleed warning, got: \(warnings)",
        )
    }

    /// The negative case guards the same path: two people on separate devices
    /// must not be told to put on headphones.
    func testDualSourceWithIndependentTracksDoesNotWarn() async throws {
        let (h, _) = try makeHarness()
        let recordings = tmpDir.appendingPathComponent("clean")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

        let appURL = recordings.appendingPathComponent("meeting_app.wav")
        let micURL = recordings.appendingPathComponent("meeting_mic.wav")
        try writeTrack(speechLike(seconds: 40, seed: 12), to: appURL)
        try writeTrack(speechLike(seconds: 40, seed: 91), to: micURL)

        await runDualSource(h, app: appURL, mic: micURL)

        // Asserting the absence of a sentence is not enough on its own: it
        // stays true when the detector never ran, which is the failure this
        // feature's own comments warn is invisible. The verdict has to be
        // present AND false — measured, and found clean.
        XCTAssertEqual(
            h.queue.jobs.first?.echo?.detected, false,
            "the clean pair must be measured and found clean, not left unmeasured",
        )
        let warnings = (h.queue.jobs.first?.warnings ?? []).joined(separator: " | ")
        XCTAssertFalse(
            warnings.contains("picked up by the microphone"),
            "independent tracks must not be reported as bleed, got: \(warnings)",
        )
    }

    // MARK: - Withholding a verdict beats guessing one

    /// A recording the detector could not read must come back as *not measured*,
    /// which is a different thing from clean. The distinction is load bearing:
    /// the naming stage lifts the embedding quarantine on `notMeasured`, and a
    /// downstream reader is told an absent `echo` means nobody looked.
    @MainActor
    func testUnreadableTrackLeavesTheJobUnmeasured() async throws {
        let (h, _) = try makeHarness()
        let dir = tmpDir.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let appURL = dir.appendingPathComponent("meeting_app.wav")
        try writeTrack(speechLike(seconds: 40, seed: 31), to: appURL)

        let id = UUID()
        let analysis = await h.queue.measureEchoBleed(
            jobID: id,
            appURL: appURL,
            micURL: dir.appendingPathComponent("never-written.wav"),
            micDelay: 0,
        )
        XCTAssertEqual(analysis.verdict, .notMeasured)
    }

    /// Two tracks at different sample rates are the case that would produce a
    /// confident *wrong* answer rather than none: one rate feeds both envelopes,
    /// so the second track's time base would silently be off by that ratio and
    /// every lag with it. Withholding is the only honest result.
    @MainActor
    func testMismatchedSampleRatesLeaveTheJobUnmeasured() async throws {
        let (h, _) = try makeHarness()
        let dir = tmpDir.appendingPathComponent("rate-mismatch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Same content on both sides, so a detector that ignored the mismatch
        // would have every reason to report something.
        let far = speechLike(seconds: 40, seed: 32)
        let appURL = dir.appendingPathComponent("meeting_app.wav")
        let micURL = dir.appendingPathComponent("meeting_mic.wav")
        try AudioMixer.saveWAV(samples: far, sampleRate: 16000, url: appURL)
        try AudioMixer.saveWAV(samples: far, sampleRate: 8000, url: micURL)

        let id = UUID()
        h.queue.enqueue(PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil, appPath: appURL, micPath: micURL, micDelay: 0,
        ))
        let analysis = await h.queue.measureEchoBleed(
            jobID: id, appURL: appURL, micURL: micURL, micDelay: 0,
        )
        XCTAssertEqual(analysis.verdict, .notMeasured)
        XCTAssertNil(
            h.queue.jobs.first?.echo,
            "nothing may be recorded on the job either; a stored verdict here would read as measured",
        )
    }

    // MARK: - Dedup: the far end appears once, the local speaker survives

    /// Builds a pair whose first half is nothing but the loudspeaker coming back
    /// and whose second half is the person at the machine talking into a silent
    /// far end. The mock engine returns the same two segments for both tracks,
    /// which is exactly the duplication a real bleed produces.
    private func writeDedupPair(_ dir: URL, bleed: Bool) throws -> (app: URL, mic: URL) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rate = EchoTestAudio.rate
        var far = speechLike(seconds: 60, seed: 71)
        // Far end silent for the second half, so the local half cannot be echo.
        for i in (30 * rate) ..< far.count {
            far[i] = 0
        }

        var mic = bleed
            ? EchoTestAudio.bleed(far, delayMs: 15, gain: 0.5)
            : speechLike(seconds: 60, seed: 72)
        let local = speechLike(seconds: 60, seed: 73)
        for i in (30 * rate) ..< mic.count {
            mic[i] = local[i]
        }

        let appURL = dir.appendingPathComponent("meeting_app.wav")
        let micURL = dir.appendingPathComponent("meeting_mic.wav")
        try writeTrack(far, to: appURL)
        try writeTrack(mic, to: micURL)
        return (appURL, micURL)
    }

    private func micLines(_ transcript: String) -> [String] {
        transcript.split(separator: "\n").map(String.init).filter { $0.contains("] Me:") }
    }

    /// The acceptance criterion for the whole feature: a unique sentence spoken
    /// locally has to survive while the far end is running, and the far end's
    /// own words must stop appearing twice.
    @MainActor
    func testBleedIsWrittenOnceAndLocalSpeechSurvives() async throws {
        let (h, _) = try makeHarness()
        h.engine.segmentsToReturn = [
            TimestampedSegment(start: 2, end: 28, text: "far end talking"),
            TimestampedSegment(start: 32, end: 58, text: "local sentence"),
        ]
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("dedup-bleed"), bleed: true)

        await runDualSource(h, app: pair.app, mic: pair.mic)

        let transcript = try String(
            contentsOf: XCTUnwrap(h.queue.jobs.first?.transcriptPath), encoding: .utf8,
        )
        let kept = micLines(transcript)
        XCTAssertEqual(kept.count, 1, "the echoed half must not be written a second time, got:\n\(transcript)")
        XCTAssertTrue(
            kept.first?.contains("local sentence") ?? false,
            "the surviving microphone line must be the one nobody played, got: \(kept)",
        )
        XCTAssertEqual(
            h.queue.jobs.first?.echo?.suppressedSegments, 1,
            "the count is the only machine-readable evidence that anything was removed",
        )
    }

    /// With the app track lost to a transcription failure, the far end exists
    /// only on the microphone. Dedup must not remove it as a copy of a
    /// transcript that was never written.
    @MainActor
    func testBleedIsKeptWhenTheAppTrackFailedToTranscribe() async throws {
        let (h, _) = try makeHarness()
        h.engine.segmentsToReturn = [
            TimestampedSegment(start: 2, end: 28, text: "far end talking"),
            TimestampedSegment(start: 32, end: 58, text: "local sentence"),
        ]
        h.engine.throwingPathSuffixes = ["app_16k.wav"]
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("dedup-app-failed"), bleed: true)

        await runDualSource(h, app: pair.app, mic: pair.mic)

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.state, .done, "error: \(job.error ?? "none")")
        let transcript = try String(contentsOf: XCTUnwrap(job.transcriptPath), encoding: .utf8)
        XCTAssertEqual(micLines(transcript).count, 2, "the only copy of the far end was removed, got:\n\(transcript)")
        XCTAssertEqual(job.echo?.suppressedSegments ?? 0, 0)
    }

    /// What the transcripts of an affected recording look like once the far
    /// end falls silent: the app track has one utterance, the microphone has
    /// its bleed copy plus the local answer right behind it. The two mic
    /// segments share a diarized speaker and sit within the merge gap, which
    /// is the arrangement that folds the suppressed copy into a kept block.
    private func configureDedupTracks(_ engine: MockEngine) {
        engine.segmentsByPathSuffix = [
            "app_16k.wav": [
                TimestampedSegment(start: 2, end: 28, text: "far end talking"),
            ],
            "mic_16k.wav": [
                TimestampedSegment(start: 2, end: 28, text: "far end talking"),
                TimestampedSegment(start: 29, end: 58, text: "local sentence"),
            ],
        ]
    }

    /// Counts calls so a test can tell "the canceller ran" from "the audio
    /// happened to come out the same", which no assertion on the transcript
    /// can distinguish when the engine is a mock that ignores its input.
    private final class CountingCanceller: EchoCancelling, @unchecked Sendable {
        let calls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let medianReduction: Float

        init(medianReduction: Float) {
            self.medianReduction = medianReduction
        }

        func cancelEcho(
            micURL: URL, referenceURL _: URL, outputURL: URL, referenceLead _: TimeInterval,
        ) throws -> EchoCancellationReport {
            calls.withLock { $0 += 1 }
            let samples = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
            try AudioMixer.saveWAV(
                samples: [Float](repeating: 0, count: samples.count),
                sampleRate: AudioConstants.targetSampleRate, url: outputURL,
            )
            // Both populations: the self-check is a difference between the
            // windows carrying echo and the ones carrying none.
            return EchoCancellationReport(windows: (0 ..< 30).map { _ in
                EchoCancellationWindow(referenceDBFS: -20, reductionDb: medianReduction)
            } + (0 ..< 20).map { _ in
                EchoCancellationWindow(referenceDBFS: -80, reductionDb: 0.2)
            })
        }
    }

    /// The whole chain in one run, which the unit tests only cover in pieces:
    /// the recording is measured, the remedy is resolved to cancellation, the
    /// microphone track is replaced, the transcript dedup does not run on top
    /// of it, and the warning says what actually happened.
    ///
    /// The transcript is deliberately not asserted on. The engine is a mock
    /// that returns segments by path suffix and never reads the audio, so it
    /// cannot notice that the far end is gone; asserting on its output would
    /// be asserting on the mock. What is checkable here is the decision, and
    /// the decision is the thing that had no end-to-end cover.
    @MainActor
    func testCancellationRunsAndTheDedupStandsDown() async throws {
        let canceller = CountingCanceller(medianReduction: 30)
        let (h, _) = try makeHarness(
            echoDedupEnabled: true,
            echoCancellationEnabled: true,
        ) { canceller }
        configureDedupTracks(h.engine)
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("cancel-e2e"), bleed: true)

        await runDualSource(h, app: pair.app, mic: pair.mic)

        XCTAssertEqual(canceller.calls.withLock { $0 }, 1, "the canceller has to have run")
        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.echo?.detected, true, "measured before the repair, not after it")
        // The discriminating assertion, not a tautology: this is the same
        // fixture and the same mock segments that make the dedup suppress
        // exactly one line two tests up. Under cancellation nothing may be
        // taken out of the transcript, because the far end was taken out of
        // the audio instead and the dedup's measure no longer means what it
        // was calibrated to mean.
        XCTAssertEqual(job.echo?.suppressedSegments ?? 0, 0)
        let transcript = try String(
            contentsOf: XCTUnwrap(job.transcriptPath), encoding: .utf8,
        )
        XCTAssertEqual(
            micLines(transcript).count, 2,
            "no microphone line may be dropped, got:\n\(transcript)",
        )
        XCTAssertTrue(
            job.warnings.contains { $0.contains("removed from the microphone track") },
            "the warning must not still be recommending headphones for a fixed recording, got: \(job.warnings)",
        )
        // The same fact on the channel a driver reads. The warning is prose and
        // free to be reworded; this is what a caller can assert on.
        XCTAssertTrue(try XCTUnwrap(job.echo?.removed))
    }

    /// The same run on a recording nobody called affected. The canceller costs
    /// time and can only take something away, so it must not fire on the large
    /// majority of recordings that have no echo at all.
    @MainActor
    func testCancellationStaysOffACleanRecording() async throws {
        let canceller = CountingCanceller(medianReduction: 30)
        let (h, _) = try makeHarness(
            echoCancellationEnabled: true,
        ) { canceller }
        configureDedupTracks(h.engine)
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("cancel-clean"), bleed: false)

        await runDualSource(h, app: pair.app, mic: pair.mic)

        XCTAssertEqual(canceller.calls.withLock { $0 }, 0)
        XCTAssertEqual(h.queue.jobs.first?.echo?.detected, false)
        // Absent, not false: false is reserved for a run that happened and could
        // not be confirmed, and a clean recording nobody attempted must not be
        // counted among those.
        XCTAssertNil(h.queue.jobs.first?.echo?.removed)
    }

    /// The same acceptance criterion with diarization on, which is the default.
    /// Stage 2 re-renders the transcript from the cached segments, and that
    /// second rendering has to leave the suppressed copies out BEFORE speaker
    /// blocks are merged — a suppressed segment that merges into an adjacent
    /// kept block smuggles its text past the final render filter. Otherwise
    /// the user with default settings gets the duplicates back while the job
    /// still reports them as removed.
    @MainActor
    func testDiarizedTranscriptAlsoWritesTheFarEndOnce() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        configureDedupTracks(h.engine)
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("dedup-diarized"), bleed: true)

        await runDualSource(h, app: pair.app, mic: pair.mic)

        let transcript = try String(
            contentsOf: XCTUnwrap(h.queue.jobs.first?.transcriptPath), encoding: .utf8,
        )
        XCTAssertEqual(
            transcript.components(separatedBy: "far end talking").count - 1, 1,
            "the diarized rendering must not reintroduce the suppressed copy, got:\n\(transcript)",
        )
        XCTAssertTrue(
            transcript.contains("local sentence"),
            "the local speaker still has to survive, got:\n\(transcript)",
        )
        XCTAssertEqual(h.queue.jobs.first?.echo?.suppressedSegments, 1)
    }

    /// The late re-diarization rewrite renders from the persisted segments the
    /// same way stage 2 does, so it carries the same duty: a re-run after the
    /// meeting must not resurrect the suppressed copies either.
    @MainActor
    func testLateRerunKeepsTheFarEndWrittenOnce() async throws {
        let (h, _) = try makeHarness(diarizeEnabled: true)
        configureDedupTracks(h.engine)
        var callCount = 0
        h.queue.speakerNamingHandler = { _ in
            callCount += 1
            return callCount == 1 ? .rerun(2) : .skipped
        }
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("dedup-late"), bleed: true)

        h.queue.enqueue(PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil, appPath: pair.app, micPath: pair.mic,
            micDelay: 0,
        ))
        await h.queue.processNext()
        await awaitJobTerminalState(h.queue, timeout: 30)

        XCTAssertEqual(callCount, 2, "the rerun has to actually run the late path")
        let transcript = try String(
            contentsOf: XCTUnwrap(h.queue.jobs.first?.transcriptPath), encoding: .utf8,
        )
        XCTAssertEqual(
            transcript.components(separatedBy: "far end talking").count - 1, 1,
            "the late rewrite must not resurrect the suppressed copy, got:\n\(transcript)",
        )
        XCTAssertTrue(transcript.contains("local sentence"))
    }

    /// Off means off. A switch that quietly keeps working is worse than none,
    /// and this one exists precisely for someone who wants the raw two-track
    /// text back, so it has to be provable rather than assumed.
    @MainActor
    func testDedupSwitchedOffKeepsTheDuplicates() async throws {
        let (h, _) = try makeHarness(echoDedupEnabled: false)
        h.engine.segmentsToReturn = [
            TimestampedSegment(start: 2, end: 28, text: "far end talking"),
            TimestampedSegment(start: 32, end: 58, text: "local sentence"),
        ]
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("dedup-off"), bleed: true)

        await runDualSource(h, app: pair.app, mic: pair.mic)

        let transcript = try String(
            contentsOf: XCTUnwrap(h.queue.jobs.first?.transcriptPath), encoding: .utf8,
        )
        XCTAssertEqual(h.queue.jobs.first?.echo?.detected, true, "the warning still fires; only the removal is off")
        XCTAssertEqual(micLines(transcript).count, 2, "with dedup off the second copy has to stay")
        XCTAssertEqual(h.queue.jobs.first?.echo?.suppressedSegments, 0)
    }

    /// The control that stops the feature from being a plain "drop the mic
    /// track": two people on separate devices keep every word they said.
    @MainActor
    func testIndependentTracksKeepEveryMicrophoneLine() async throws {
        let (h, _) = try makeHarness()
        h.engine.segmentsToReturn = [
            TimestampedSegment(start: 2, end: 28, text: "far end talking"),
            TimestampedSegment(start: 32, end: 58, text: "local sentence"),
        ]
        let pair = try writeDedupPair(tmpDir.appendingPathComponent("dedup-clean"), bleed: false)

        await runDualSource(h, app: pair.app, mic: pair.mic)

        let transcript = try String(
            contentsOf: XCTUnwrap(h.queue.jobs.first?.transcriptPath), encoding: .utf8,
        )
        XCTAssertEqual(h.queue.jobs.first?.echo?.detected, false, "the control must be measured and found clean")
        XCTAssertEqual(micLines(transcript).count, 2, "nothing may be removed from a recording without bleed")
    }

    /// The classification step has the same duty as the detector: an unreadable
    /// or mismatched pair yields no verdicts, so the merge leaves every segment
    /// alone. Silently classifying against a half-read track would remove lines
    /// on evidence nobody has.
    @MainActor
    func testClassificationWithAnUnreadableTrackRemovesNothing() async throws {
        let (h, _) = try makeHarness()
        let dir = tmpDir.appendingPathComponent("classify-unreadable")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let appURL = dir.appendingPathComponent("meeting_app.wav")
        try writeTrack(speechLike(seconds: 40, seed: 81), to: appURL)

        let verdicts = await h.queue.classifyMicEcho(
            remedy: .transcriptDedup,
            analysis: EchoBleedAnalysis(verdict: .affected),
            tracks: (
                app: appURL,
                mic: dir.appendingPathComponent("never-written.wav"),
                micDelay: 0,
            ),
            micSegments: [TimestampedSegment(start: 0, end: 10, text: "x")],
        )
        XCTAssertTrue(verdicts.isEmpty)
    }

    /// Nothing is classified on a recording nobody called affected, and nothing
    /// on one with no microphone segments. Both are the cheap exits that keep
    /// the second audio decode off the ordinary path.
    @MainActor
    func testClassificationSkipsUnaffectedRecordingsEntirely() async throws {
        let (h, _) = try makeHarness()
        let dir = tmpDir.appendingPathComponent("classify-clean")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let appURL = dir.appendingPathComponent("meeting_app.wav")
        let micURL = dir.appendingPathComponent("meeting_mic.wav")
        let far = speechLike(seconds: 40, seed: 82)
        try writeTrack(far, to: appURL)
        try writeTrack(EchoTestAudio.bleed(far, delayMs: 15, gain: 0.5), to: micURL)
        let segments = [TimestampedSegment(start: 2, end: 30, text: "x")]

        for verdict in [EchoVerdict.clean, .notMeasured] {
            let out = await h.queue.classifyMicEcho(
                remedy: .transcriptDedup,
                analysis: EchoBleedAnalysis(verdict: verdict),
                tracks: (app: appURL, mic: micURL, micDelay: 0), micSegments: segments,
            )
            XCTAssertTrue(out.isEmpty, "\(verdict) must not classify anything, even on audio that would light up")
        }
        let noSegments = await h.queue.classifyMicEcho(
            remedy: .transcriptDedup,
            analysis: EchoBleedAnalysis(verdict: .affected),
            tracks: (app: appURL, mic: micURL, micDelay: 0), micSegments: [],
        )
        XCTAssertTrue(noSegments.isEmpty)
    }
}
