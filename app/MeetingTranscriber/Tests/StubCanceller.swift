import Foundation
@testable import MeetingTranscriber

/// Stands in for the echo canceller's model in every test that drives the
/// cancellation stage. Shared so there is one place that knows what report
/// shape the self-check confirms; a second stub with its own copy of that
/// shape would drift from this one the first time the threshold moved.
///
/// The model is a separate ~3 MB download that no CI job has, and what the
/// stage tests pin is its decisions — replace or keep, warn or stay quiet —
/// not the quality of the audio, which `LocalVQECancellerFileTests` covers.
struct StubCanceller: EchoCancelling {
    let report: EchoCancellationReport
    let failure: (any Error)?
    /// Written by the stub so a test can tell "produced silence" from
    /// "never ran", which an assertion on the file's contents alone cannot.
    let marker: Float
    let writesOutput: Bool
    /// How long the run pretends to take, for tests that time it.
    let delay: Duration

    init(
        medianReduction: Float,
        failure: (any Error)? = nil,
        marker: Float = 0.25,
        quietWindows: Int = 20,
        writesOutput: Bool = true,
        delay: Duration = .zero,
    ) {
        self.writesOutput = writesOutput
        self.delay = delay
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
    ) async throws -> EchoCancellationReport {
        if delay > .zero { try await Task.sleep(for: delay) }
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

extension PipelineQueue {
    /// A queue with echo cancellation on and `canceller` standing in for the
    /// model. A nil canceller is "no model could be resolved", which is a
    /// different branch from a canceller that fails once it runs.
    static func withEchoCanceller(
        _ canceller: StubCanceller?, logDir: URL, stageTimingLog: StageTimingLog? = nil,
    ) -> PipelineQueue {
        // Bound to a local first: as a trailing argument the formatter
        // detaches it from the call.
        let factory: () -> (any EchoCancelling)? = { canceller }
        return PipelineQueue(
            logDir: logDir, stageTimingLog: stageTimingLog,
            echoCancellationEnabled: { true }, echoCancellerFactory: factory,
        )
    }

    /// A verdict to hang a cancellation outcome on. Every real call site has
    /// one: the stage only reaches cancellation on an `.affected` verdict,
    /// which is recorded before it runs.
    func seedAffectedEchoVerdict(jobID: UUID) {
        recordEchoVerdict(jobID: jobID, EchoDetectionDTO(EchoBleedDetector.Result(
            windowScores: [EchoBleedDetector.WindowScore(correlation: 0.9, lagSeconds: 0.015)],
        )))
    }
}

extension EchoTestAudio {
    /// The two 16 kHz tracks a dual-source job hands the cancellation stage,
    /// written under the names the pipeline uses for them, with independent
    /// talkers on each.
    static func writeTrackPair(into dir: URL, seconds: Double = 2) throws -> (app: URL, mic: URL) {
        let app = dir.appendingPathComponent("app_16k.wav")
        let mic = dir.appendingPathComponent("mic_16k.wav")
        for (url, seed) in [(app, UInt64(1)), (mic, UInt64(2))] {
            try AudioMixer.saveWAV(
                samples: speechLike(seconds: seconds, seed: seed),
                sampleRate: AudioConstants.targetSampleRate, url: url,
            )
        }
        return (app, mic)
    }
}
