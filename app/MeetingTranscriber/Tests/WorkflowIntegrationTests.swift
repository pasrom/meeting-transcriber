// swiftlint:disable file_length
@testable import MeetingTranscriber
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

    /// Reference-type collector for state transitions captured via onJobStateChange.
    private final class TransitionCollector {
        var transitions: [(JobState, JobState)] = []
    }

    private func makeHarness(
        diarizeEnabled: Bool = false,
        stagingDir: URL? = nil,
        echoDedupEnabled: Bool = true,
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

        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: stagingDir ?? AppPaths.recordingsDir,
            diarizeEnabled: diarizeEnabled,
            echoDedupEnabled: echoDedupEnabled,
            micLabel: "Me",
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
        let analysis = await h.queue.warnIfEchoBleed(
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
        let analysis = await h.queue.warnIfEchoBleed(
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
            analysis: EchoBleedAnalysis(verdict: .affected),
            appURL: appURL,
            micURL: dir.appendingPathComponent("never-written.wav"),
            micDelay: 0,
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
                analysis: EchoBleedAnalysis(verdict: verdict),
                appURL: appURL, micURL: micURL, micDelay: 0, micSegments: segments,
            )
            XCTAssertTrue(out.isEmpty, "\(verdict) must not classify anything, even on audio that would light up")
        }
        let noSegments = await h.queue.classifyMicEcho(
            analysis: EchoBleedAnalysis(verdict: .affected),
            appURL: appURL, micURL: micURL, micDelay: 0, micSegments: [],
        )
        XCTAssertTrue(noSegments.isEmpty)
    }
}
