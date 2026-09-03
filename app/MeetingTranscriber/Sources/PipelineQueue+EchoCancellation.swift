// The cancellation half of the echo work: takes the far end out of the
// microphone track before anything reads it. Sits beside
// PipelineQueue+EchoBleed.swift, which measures, and is the other branch of
// the same decision (`EchoRemedy`).
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue+EchoCancellation")

extension PipelineQueue {
    /// Rewrites the 16 kHz microphone track with the far end removed, in place.
    ///
    /// In place, and that is the design rather than an economy. Everything
    /// downstream reads `mic_16k.wav` from the work directory by convention:
    /// transcription, the per-track diarization, and through it the speaker
    /// embeddings. Replacing the file is what makes all three see a cleaned
    /// track without a second path threaded through the pipeline, and without
    /// a future reader having to remember which of two microphone files it is
    /// supposed to open.
    ///
    /// Returns whether the echo can honestly be said to be gone, which is not
    /// the same as whether the run completed: the model sometimes removes
    /// nothing while reporting success, so the answer is the self-check's, not
    /// the file system's. A false here is not an error the job should fail on
    /// — the track is left as recorded, which is what shipped before this
    /// existed — but the user is told, because a feature that is on and
    /// silently doing nothing is the failure mode this direction keeps
    /// running into.
    func cancelEchoOnMicTrack(
        jobID: UUID, appURL: URL, micURL: URL, micDelay: TimeInterval,
    ) async throws -> Bool {
        guard let canceller = echoCancellerFactory() else {
            logger.warning("echo_cancel skipped: no model available")
            addWarning(
                id: jobID,
                "Echo cancellation is on but its model is missing, so the microphone track was left as recorded.",
            )
            return false
        }
        let staged = micURL.deletingLastPathComponent()
            .appendingPathComponent("mic_16k_cancelled.wav")
        let report: EchoCancellationReport
        do {
            report = try await canceller.cancelEcho(
                micURL: micURL, referenceURL: appURL, outputURL: staged,
                // Clamped exactly as the detector and the mix clamp it, and for
                // the same reason: a device switch mid-recording can reset one
                // source's first-frame timestamp, and an absurd lead would seek
                // the reference past the end of itself.
                referenceLead: AudioMixer.clampMicDelay(micDelay),
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: staged)
            // Rethrown, not turned into "declined". The job is already gone
            // from the queue by the time this arrives, so swallowing it let the
            // run continue into two transcription passes and write artifacts
            // for a recording the user had cancelled.
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            logger.error(
                "echo_cancel failed error=\(error.localizedDescription, privacy: .public)",
            )
            addWarning(
                id: jobID,
                "Echo cancellation failed, so the microphone track was left as recorded.",
            )
            return false
        }

        // Judged before it is adopted, which is the whole reason the seam hands
        // the report back before the swap. Adopting first and asking after left
        // the model's output in place on exactly the runs that could not be
        // shown to have improved it.
        let effect = EchoCancellationSelfCheck.effect(of: report)
        logger.info(
            "echo_cancel windows=\(report.windows.count, privacy: .public) effect=\(String(describing: effect), privacy: .public)",
        )
        guard effect == .removed else {
            try? FileManager.default.removeItem(at: staged)
            addWarning(id: jobID, Self.unconfirmedWarning(for: effect))
            return false
        }
        return adopt(staged: staged, as: micURL, jobID: jobID)
    }

    /// Puts the cancelled track where every later stage will look for it, by
    /// renames whose failure states are defined.
    ///
    /// Not `replaceItemAt`. That reads as the safe primitive and its success
    /// path is exactly right, but its documentation says nothing about where
    /// the original is when it throws, and the recovery here was written as
    /// though it did: delete the staged file and report that the recording was
    /// left as recorded. Two reviewers disagreed about whether that can lose
    /// the original, which is the answer by itself. Every step below is a
    /// rename inside one directory, so each either happened or did not, and
    /// the step that undoes it is written out.
    private func adopt(staged: URL, as micURL: URL, jobID: UUID) -> Bool {
        let manager = FileManager.default
        let backup = micURL.appendingPathExtension("original")
        try? manager.removeItem(at: backup)
        do {
            try manager.moveItem(at: micURL, to: backup)
        } catch {
            // Nothing has moved, so the recording is where it always was.
            try? manager.removeItem(at: staged)
            return reportAdoptFailure(error, jobID: jobID)
        }
        do {
            try manager.moveItem(at: staged, to: micURL)
        } catch {
            try? manager.moveItem(at: backup, to: micURL)
            try? manager.removeItem(at: staged)
            return reportAdoptFailure(error, jobID: jobID)
        }
        try? manager.removeItem(at: backup)
        return true
    }

    /// Close to unreachable: both files sit in this run's own work directory.
    /// Reported rather than thrown because the original track is still there
    /// and still usable, and losing a meeting over a rename would be a worse
    /// outcome than an echo left in.
    private func reportAdoptFailure(_ error: any Error, jobID: UUID) -> Bool {
        logger.error(
            "echo_cancel adopt failed error=\(error.localizedDescription, privacy: .public)",
        )
        addWarning(
            id: jobID,
            "Echo cancellation finished but its result could not be used, so the microphone track was left as recorded.",
        )
        return false
    }

    /// What to tell the user about a run whose output is not being used.
    ///
    /// All of them say "left as recorded" because all of them now do that. The
    /// distinction they keep is what happened, because the three ask for
    /// different things: a run that did nothing is a fault worth reporting
    /// upstream, a run nobody could judge is usually a far end that never
    /// paused long enough to measure against, and a run that damaged the
    /// quiet stretches is the one case where the model actively made the
    /// recording worse.
    private static func unconfirmedWarning(for effect: EchoCancellationSelfCheck.Effect) -> String {
        switch effect {
        case .ineffective:
            "Echo cancellation ran but removed almost nothing, so the microphone track was left as recorded."

        case .damagedControl:
            "Echo cancellation altered parts of the recording where there was no echo, so the microphone track was left as recorded."

        case .indeterminate:
            "Echo cancellation could not be confirmed on this recording, so the microphone track was left as recorded."

        case .removed:
            ""
        }
    }

    /// The production canceller: whatever `LocalVQEModel` resolves out of the
    /// bundle or the override variable, or nil when neither is there.
    ///
    /// The three pieces of ambient state are default arguments rather than
    /// reads in the body, the same way `LocalVQEModel.resolve` already takes
    /// its `fileExists`. Read inline they made the one decision here — a
    /// resolution that came up empty means no canceller, and reporting that is
    /// how the user learns the feature is not running — reachable only by
    /// arranging the machine the test happened to run on.
    static func bundledEchoCanceller(
        override: String? = ProcessInfo.processInfo.environment[LocalVQEModel.overrideEnvironmentKey],
        bundledPath: String? = LocalVQEModel.bundledModelPath(in: .main),
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
    ) -> (any EchoCancelling)? {
        guard let path = LocalVQEModel.resolve(
            override: override, bundledPath: bundledPath, fileExists: fileExists,
        ).path else { return nil }
        return LocalVQECanceller(modelPath: path)
    }
}
