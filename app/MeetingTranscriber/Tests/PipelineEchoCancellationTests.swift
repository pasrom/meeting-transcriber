@testable import MeetingTranscriber
import XCTest

/// The cancellation stage: what it does to the microphone track, and what it
/// tells the user when it cannot.
///
/// Driven with a stub canceller rather than the real model. The model is a
/// separate ~3 MB download that no CI job has, and what is under test here is
/// the stage's decisions — replace or keep, warn or stay quiet — not the
/// quality of the audio, which `LocalVQECancellerFileTests` covers.
@MainActor
final class PipelineEchoCancellationTests: XCTestCase {
    private struct StubCanceller: EchoCancelling {
        let report: EchoCancellationReport
        let failure: (any Error)?
        /// Written by the stub so a test can tell "produced silence" from
        /// "never ran", which an assertion on the file's contents alone cannot.
        let marker: Float
        let writesOutput: Bool

        init(
            medianReduction: Float,
            failure: (any Error)? = nil,
            marker: Float = 0.25,
            quietWindows: Int = 20,
            writesOutput: Bool = true,
        ) {
            self.writesOutput = writesOutput
            // Both populations, because the self-check is a difference: the
            // windows carrying echo AND the ones carrying none, which a healthy
            // run leaves alone. A stub that emitted only the first would be
            // asking a question the check refuses to answer.
            report = EchoCancellationReport(
                windows: (0 ..< 30).map { _ in
                    EchoCancellationWindow(referenceDBFS: -20, reductionDb: medianReduction)
                } + (0 ..< quietWindows).map { _ in
                    EchoCancellationWindow(referenceDBFS: -80, reductionDb: 0.2)
                },
            )
            self.failure = failure
            self.marker = marker
        }

        func cancelEcho(
            micURL: URL, referenceURL _: URL, outputURL: URL, referenceLead _: TimeInterval,
        ) throws -> EchoCancellationReport {
            if let failure { throw failure }
            guard writesOutput else { return report }
            let samples = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
            try AudioMixer.saveWAV(
                samples: samples.map { _ in marker },
                sampleRate: AudioConstants.targetSampleRate,
                url: outputURL,
            )
            return report
        }
    }

    private var dir = FileManager.default.temporaryDirectory

    @MainActor
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("echocancel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @MainActor
    override func tearDown() async throws {
        // Guarded rather than `try?`: with no `try` in the body the formatter
        // strips `throws`, and the override then clashes with XCTest's
        // throwing signature.
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func makeTracks() throws -> (app: URL, mic: URL) {
        let app = dir.appendingPathComponent("app_16k.wav")
        let mic = dir.appendingPathComponent("mic_16k.wav")
        try AudioMixer.saveWAV(
            samples: EchoTestAudio.speechLike(seconds: 2, seed: 1),
            sampleRate: AudioConstants.targetSampleRate, url: app,
        )
        try AudioMixer.saveWAV(
            samples: EchoTestAudio.speechLike(seconds: 2, seed: 2),
            sampleRate: AudioConstants.targetSampleRate, url: mic,
        )
        return (app, mic)
    }

    private func makeQueue(_ canceller: StubCanceller?) -> (PipelineQueue, UUID) {
        // A factory that returns nil is "no model could be resolved", which is a
        // different branch from a canceller that fails once it runs. Bound to a
        // local first: as a trailing argument the formatter detaches it from
        // the call.
        let factory: () -> (any EchoCancelling)? = { canceller }
        let queue = PipelineQueue(
            logDir: dir.appendingPathComponent("logs"),
            echoCancellationEnabled: { true },
            echoCancellerFactory: factory,
        )
        let job = PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.insertJobForTesting(job)
        return (queue, job.id)
    }

    /// The point of doing it in place: every later stage opens `mic_16k.wav`
    /// by convention, so the replacement is what makes transcription, the
    /// per-track diarization and the speaker embeddings taken from it all see
    /// a cleaned track without a second path threaded through the pipeline.
    func testASuccessfulRunReplacesTheMicrophoneTrack() async throws {
        let tracks = try makeTracks()
        let (queue, jobID) = makeQueue(StubCanceller(medianReduction: 30))

        let removed = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertTrue(removed)
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic)
        XCTAssertEqual(samples.first ?? 0, 0.25, accuracy: 0.001, "the file at the old path is the new audio")
        XCTAssertTrue(queue.jobs.first?.warnings.isEmpty ?? false, "a run that worked says nothing")
    }

    /// The measured silent failure: the run completes, writes a full-length
    /// track, and takes a tenth of a decibel off it. Nothing about that is
    /// visible from the outside, which is why it has to be said.
    func testARunThatRemovedNothingIsReportedAndNotAdopted() async throws {
        let tracks = try makeTracks()
        let before = try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic)
        let (queue, jobID) = makeQueue(StubCanceller(medianReduction: 0.2))

        let removed = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertFalse(removed, "the echo is still there, so nothing may claim it is gone")
        XCTAssertEqual(
            try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic), before,
            "a run that cannot be shown to have improved the track must not replace it",
        )
        let warnings = queue.jobs.first?.warnings ?? []
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("removed almost nothing"))
    }

    /// A run nobody could judge is not a run that failed, and the two send the
    /// user somewhere different. Reached here by a far end that never pauses,
    /// which leaves no control group to compare against.
    func testAnUnjudgeableRunSaysSoAndIsNotAdopted() async throws {
        let tracks = try makeTracks()
        let before = try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic)
        let (queue, jobID) = makeQueue(StubCanceller(medianReduction: 30, quietWindows: 0))

        let removed = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic), before)
        XCTAssertTrue(
            (queue.jobs.first?.warnings ?? []).contains { $0.contains("could not be confirmed") },
        )
    }

    /// The adoption itself can fail, and the recovery must not be the thing
    /// that loses the recording. Written as a remove followed by a move, a
    /// remove that succeeded before a move that failed left no microphone
    /// track at all, while the warning said it had been left as recorded.
    func testAFailedAdoptionStillLeavesTheOriginalTrack() async throws {
        let tracks = try makeTracks()
        let before = try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic)
        let (queue, jobID) = makeQueue(StubCanceller(medianReduction: 30, writesOutput: false))
        seedVerdict(queue, jobID)

        let removed = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertFalse(removed)
        // The sharpest of the four declines: the self-check confirmed this run
        // and the rename failed after it. The recording is still as it was, so
        // it counts as one the feature did not deliver on — a field meaning
        // "the self-check would not confirm it" would say the opposite here.
        XCTAssertEqual(queue.jobs.first?.echo?.removed, false)
        XCTAssertEqual(
            try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic), before,
            "the recording has to survive its own recovery path",
        )
        XCTAssertTrue(
            (queue.jobs.first?.warnings ?? []).contains { $0.contains("could not be used") },
        )
    }

    /// A canceller that throws must leave the recording exactly as it was. The
    /// job keeps going: an echo left in is worse audio, a lost microphone track
    /// is a lost meeting.
    func testAFailedRunKeepsTheOriginalTrackAndSaysSo() async throws {
        let tracks = try makeTracks()
        let before = try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic)
        let (queue, jobID) = makeQueue(StubCanceller(
            medianReduction: 30,
            failure: EchoCancellationError.processingFailed(code: 7, message: "boom"),
        ))

        let removed = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic), before)
        XCTAssertTrue((queue.jobs.first?.warnings ?? []).contains { $0.contains("failed") })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic_16k_cancelled.wav").path),
            "the staged file must not be left behind for the next run to trip over",
        )
    }

    /// The setting is on and no model could be resolved. Silence would be the
    /// worst answer: the user has asked for the feature and would get a
    /// recording with the echo still in it and no reason to suspect anything.
    func testNoResolvableModelIsReportedRatherThanSilentlySkipped() async throws {
        let tracks = try makeTracks()
        let before = try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic)
        let (queue, jobID) = makeQueue(nil)

        let removed = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic), before)
        XCTAssertTrue((queue.jobs.first?.warnings ?? []).contains { $0.contains("model is missing") })
    }

    /// The production resolution, with its ambient state handed in. Two lines
    /// of decision, and the one that matters is the empty case: a resolution
    /// that came up empty has to become no canceller, which is what makes the
    /// stage report a missing model instead of running with a bad path.
    func testTheProductionResolutionTurnsAMissingModelIntoNoCanceller() {
        XCTAssertNil(PipelineQueue.bundledEchoCanceller(
            override: nil, bundledPath: nil,
        ) { _ in true })
        XCTAssertNil(
            PipelineQueue.bundledEchoCanceller(
                override: "/nope/model.gguf", bundledPath: nil,
            ) { _ in false },
            "an override that points at nothing is not a reason to fall back to the bundle",
        )
    }

    func testTheProductionResolutionUsesTheResolvedPath() throws {
        let canceller = try XCTUnwrap(PipelineQueue.bundledEchoCanceller(
            override: nil, bundledPath: "/models/localvqe.gguf",
        ) { _ in true } as? LocalVQECanceller)
        XCTAssertEqual(canceller.modelPath, "/models/localvqe.gguf")
    }

    /// Cancellation has to propagate, not become "the feature declined".
    /// Swallowed, the run continued into two transcription passes and stage
    /// three for a job the user had already removed from the queue, so the
    /// warnings and state updates went nowhere while the artifacts were still
    /// written.
    func testACancelledRunPropagatesAndLeavesTheTrackAlone() async throws {
        let tracks = try makeTracks()
        let before = try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic)
        let (queue, jobID) = makeQueue(StubCanceller(
            medianReduction: 30, failure: CancellationError(),
        ))

        do {
            _ = try await queue.cancelEchoOnMicTrack(
                jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
            )
            XCTFail("expected the cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(try AudioMixer.loadAudioFileAsFloat32(url: tracks.mic), before)
        XCTAssertTrue(
            (queue.jobs.first?.warnings ?? []).isEmpty,
            "the user stopped this job; it is not a fault to report",
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic_16k_cancelled.wav").path),
        )
    }

    // MARK: - What the outside can read

    /// A verdict to hang the outcome on. Every real call site has one: the
    /// stage only reaches cancellation on an `.affected` verdict, which is
    /// recorded before it runs.
    private func seedVerdict(_ queue: PipelineQueue, _ jobID: UUID) {
        queue.recordEchoVerdict(jobID: jobID, EchoDetectionDTO(EchoBleedDetector.Result(
            windowScores: [EchoBleedDetector.WindowScore(correlation: 0.9, lagSeconds: 0.015)],
        )))
    }

    /// A confirmed run says so on the job. Why the field exists at all, and why
    /// its three states are not two, is on `EchoDetectionDTO.removed`.
    func testAConfirmedRunIsVisibleOnTheJob() async throws {
        let tracks = try makeTracks()
        let (queue, jobID) = makeQueue(StubCanceller(medianReduction: 30))
        seedVerdict(queue, jobID)

        _ = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertEqual(queue.jobs.first?.echo?.removed, true)
    }

    /// A run the self-check would not confirm reads as a decline, not as a
    /// recording nobody tried to repair. This is the state the field is shaped
    /// around, so it is the one worth a test of its own.
    func testADeclinedRunIsVisibleAndDistinctFromNeverHavingRun() async throws {
        let tracks = try makeTracks()
        let (queue, jobID) = makeQueue(StubCanceller(medianReduction: 0.2))
        seedVerdict(queue, jobID)

        _ = try await queue.cancelEchoOnMicTrack(
            jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
        )

        XCTAssertEqual(queue.jobs.first?.echo?.removed, false)
    }

    /// The other three ways the stage can end without the far end gone. All of
    /// them are `false`, and the reason to pin them here is that the field is
    /// documented as a count of "the feature was on and did not deliver": a
    /// version of this that only recorded the self-check's refusal would leave
    /// the other three absent, i.e. indistinguishable from a recording nobody
    /// tried to repair, which is the population the count exists to exclude.
    ///
    /// The fourth way, a confirmed run whose output could not be moved into
    /// place, is pinned where that path is already exercised.
    func testEveryWayTheStageDeclinesIsRecordedAsADecline() async throws {
        let cases: [(String, StubCanceller?)] = [
            ("no resolvable model", nil),
            ("the run threw", StubCanceller(medianReduction: 30, failure: EchoCancellationError.modelLoadFailed("x"))),
            ("the self-check refused", StubCanceller(medianReduction: 0.2)),
        ]
        for (name, canceller) in cases {
            let tracks = try makeTracks()
            let (queue, jobID) = makeQueue(canceller)
            seedVerdict(queue, jobID)

            _ = try await queue.cancelEchoOnMicTrack(
                jobID: jobID, appURL: tracks.app, micURL: tracks.mic, micDelay: 0,
            )

            XCTAssertEqual(queue.jobs.first?.echo?.removed, false, "\(name) has to read as a decline")
        }
    }
}
