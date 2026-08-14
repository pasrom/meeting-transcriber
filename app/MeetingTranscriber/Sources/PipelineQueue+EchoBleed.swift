import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue+EchoBleed")

/// Warns when a dual-source recording carries the same speech on both tracks,
/// which happens when the loudspeaker output is picked up by the microphone.
///
/// Lives in its own file rather than in `PipelineQueue+Stages.swift`, which is
/// already at the length where `file_length` had to be suppressed.
///
/// The warning rides the menu-bar job entry and the automation API, both of
/// which are always reachable. That matters: a notification is not, and this
/// app has already been bitten by making a feature depend on one being seen.
extension PipelineQueue {
    /// Only this much of a recording is analysed. The detector needs enough to
    /// characterise the meeting, not all of it, and reading a two-hour track
    /// whole would add a second large peak next to the one `mix` already makes.
    /// The affected recordings measured so far carry bleed through 34 % to 77 %
    /// of their windows, so the opening minutes show it. The cost is that bleed
    /// starting later goes unseen, which is why the warning names the span it
    /// looked at instead of claiming the whole recording.
    nonisolated static let echoBleedAnalysisSeconds = 600.0

    /// Async, and the work runs off the main actor on purpose. `PipelineQueue`
    /// is `@MainActor`; decoding up to two ten-minute tracks and running the
    /// envelope pass over them synchronously would block the UI for as long as
    /// it takes. Every neighbouring stage awaits for the same reason.
    ///
    /// The verdict is recorded on the job (`recordEchoVerdict`), which is where
    /// every later reader takes it from — the naming stage derives its
    /// `EchoVerdict` from `job.echo`. The measurement is returned so the caller
    /// can decide whether to clean the track and then report both facts
    /// together. This deliberately does NOT warn: the warning has to wait until
    /// the outcome of that cleaning is known.
    func measureEchoBleed(
        jobID: UUID, appURL: URL, micURL: URL, micDelay: TimeInterval,
    ) async -> EchoBleedDetector.Result? {
        // Clamped exactly as `AudioMixer.mix` clamps it, and for the same
        // reason: a device switch mid-recording can reset the first-frame
        // timestamp on one source only (issue #99), and an absurd delay here
        // would push every candidate lag past the end of the window, so every
        // window scores nil and the whole detector silently no-ops.
        let delay = AudioMixer.clampMicDelay(micDelay)
        let result = await Task.detached(priority: .utility) { () -> EchoBleedDetector.Result? in
            let analysed = Self.echoBleedAnalysisSeconds
            guard let (app, appRate) = Self.loadBounded(appURL, maxSeconds: analysed),
                  let (mic, micRate) = Self.loadBounded(micURL, maxSeconds: analysed)
            else {
                logger.warning("echo_bleed skipped: a track could not be read")
                return nil
            }
            // One rate feeds both envelopes, so mismatched tracks would sit on
            // different time bases and every lag would be meaningless — a
            // confident wrong verdict rather than an absent one.
            guard appRate == micRate else {
                logger.warning("echo_bleed skipped: track sample rates differ (\(appRate, privacy: .public) vs \(micRate, privacy: .public))")
                return nil
            }
            return EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: appRate, micDelay: delay)
        }.value

        guard let result else { return nil }
        let percent = Int((result.affectedWindowShare * 100).rounded())
        let scored = result.windowsScored
        let hits = result.windowsAffected
        // Recorded whether or not it fires. A driver, and a field report, must be
        // able to tell "analysed, nothing found" from "never analysed", and a
        // near-miss share is what makes a false negative diagnosable later.
        recordEchoVerdict(jobID: jobID, EchoDetectionDTO(result))
        logger.info("echo_bleed share=\(percent, privacy: .public)% windows=\(scored, privacy: .public) affected=\(hits, privacy: .public)")
        // The per-window series, so a field report is diagnosable with no audio
        // attached. It answers the two questions the share alone cannot: whether
        // a miss sat just under the threshold or nowhere near it, and whether the
        // windows peaked at one stable lag (bleed travels a fixed path) or
        // scattered across the search range (a coincidence). Numbers only — no
        // audio, no transcript, nothing derived from what was said.
        let detail = Self.windowDetail(result.windowScores)
        logger.info("echo_bleed windows=\(detail, privacy: .public)")
        return result
    }

    /// Tells the user what was found and what was done about it.
    ///
    /// Emitted after the cancellation attempt, not before it. The earlier
    /// version warned first and cleaned afterwards, so a successfully cleaned
    /// recording carried a permanent warning saying its speech would appear
    /// twice and its voices would not be learned — both false by then, and both
    /// visible in the menu bar, the API and the persisted job forever.
    func warnAboutEcho(jobID: UUID, result: EchoBleedDetector.Result, cancelled: Bool) {
        // Says what was measured, not more: the share is over the windows that
        // were scored inside the analysed span, which for a long meeting is a
        // fraction of it.
        let percent = Int((result.affectedWindowShare * 100).rounded())
        let analysedSeconds = Double(result.windowsScored) * EchoBleedDetector.windowSeconds
        let minutes = Int((analysedSeconds / 60).rounded())
        // "1 minutes" is reachable: the minimum firing configuration is three
        // ten-second windows, and the E2E fixture produces four.
        let span = minutes == 1 ? "minute" : "minutes"
        let head = "Speaker output was picked up by the microphone in \(percent)% of the \(minutes) \(span) analysed."
        if cancelled {
            addWarning(id: jobID, "\(head) It was removed from the recording automatically. Using headphones avoids it entirely.")
            return
        }
        let tail = "Remote speech may appear twice in the transcript. Using headphones avoids it."
        // Third sentence because the consequence is otherwise invisible: naming
        // speakers on this recording will look like it worked and teach the app
        // nothing.
        let db = "Voices from this recording are not added to the speaker database."
        addWarning(id: jobID, "\(head) \(tail) \(db)")
    }

    /// Renders the per-window series as `corr@lagms` pairs, e.g.
    /// `0.79@20 0.83@20 0.87@10`. Compact on purpose: this goes out on every
    /// dual-source job, and a long recording has dozens of windows.
    nonisolated static func windowDetail(_ scores: [EchoBleedDetector.WindowScore]) -> String {
        scores.map { score in
            let corr = String(format: "%.2f", score.correlation)
            let lagMs = Int((score.lagSeconds * 1000).rounded())
            return "\(corr)@\(lagMs)"
        }.joined(separator: " ")
    }

    /// Reads at most `maxSeconds` of a mono file as Float32. `nonisolated` so it
    /// can run off the main actor.
    nonisolated private static func loadBounded(_ url: URL, maxSeconds: Double) -> ([Float], Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = Int(file.processingFormat.sampleRate)
        guard rate > 0 else { return nil }
        let wanted = min(Double(file.length), maxSeconds * Double(rate))
        let frames = AVAudioFrameCount(wanted)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer, frameCount: frames)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), rate)
    }
}

extension PipelineQueue {
    /// Removes the loudspeaker echo from the 16 kHz microphone track, and only
    /// reports success when the removal is **measured**.
    ///
    /// The flag this sets is consumed by the speaker-database quarantine, so an
    /// attempt marker will not do: a canceller that runs and achieves nothing
    /// would lift the very protection the detection exists for. So the detector
    /// is re-run on the cleaned track, and the track is only adopted when the
    /// bleed is actually gone. Re-measuring costs about what the first
    /// measurement cost, which is a rounding error against transcription.
    ///
    /// **Overwriting `mic_16k.wav` is the design.** Transcription, the
    /// dual-track diarization, and the `<slug>_mic_16k.wav` sidecar that late
    /// re-diarization reads back all take that one path, so cleaning it once
    /// fixes every consumer. The cleaned audio is written beside it first and
    /// only swapped in after it verifies, so a failure leaves the run's track
    /// exactly as it was.
    ///
    /// Returns whether the track was replaced. Every failure is soft.
    func cancelEcho(
        jobID: UUID, appURL: URL, micURL: URL, micDelay: TimeInterval,
    ) async -> Bool {
        guard let modelPath = await EchoCancellerModel.ensureAvailable() else {
            logger.warning("echo_cancel_skipped: weights unavailable")
            return false
        }
        let delay = AudioMixer.clampMicDelay(micDelay)
        let staged = micURL.deletingLastPathComponent().appendingPathComponent("mic_16k_aec.wav")

        let verified = await Task.detached(priority: .utility) { () -> Bool in
            guard let canceller = EchoCanceller(modelPath: modelPath) else { return false }
            do {
                let app = try AudioMixer.loadAudioFileAsFloat32(url: appURL)
                let mic = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
                let rate = AudioConstants.targetSampleRate
                let cleaned = try canceller.process(
                    mic: mic,
                    reference: Self.alignReference(app, micDelay: delay, sampleRate: rate),
                )
                // Prove it worked before anything downstream can read it. Same
                // detector, same delay, so the two numbers are comparable.
                //
                // A `nil` verdict here is SUCCESS, not failure. The same call on
                // the same tracks returned a measurement moments ago, so nothing
                // about length or overlap can have changed — the only thing that
                // can is the microphone dropping below the signal floor, which
                // is the echo being gone entirely. Measured on a track that was
                // pure bleed: 4 of 4 windows before, too quiet to measure after.
                // Reading that as a failed cancellation would reject the best
                // possible outcome and keep the quarantine on a clean recording.
                let after = EchoBleedDetector.analyse(
                    app: app, mic: cleaned, sampleRate: rate, micDelay: delay,
                )
                guard after?.isAffected != true else {
                    logger.warning("echo_cancel_ineffective: the bleed is still measurable, keeping the recording as captured")
                    return false
                }
                try AudioMixer.saveWAV(samples: cleaned, sampleRate: rate, url: staged)
                _ = try FileManager.default.replaceItemAt(micURL, withItemAt: staged)
                return true
            } catch {
                logger.error("echo_cancel_failed \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: staged)
                return false
            }
        }.value

        if verified {
            recordEchoCancelled(jobID: jobID)
            logger.info("echo_cancel_applied")
        }
        return verified
    }

    /// Shifts the app track onto the microphone's own timeline.
    ///
    /// The canceller pairs `reference[i]` with `mic[i]`, and the model estimates
    /// only the acoustic delay — a few tens of milliseconds — never a file
    /// offset. `micDelay > 0` means the mic started late, so `mic[i]` was
    /// recorded while `app[i + delay]` was playing. Feeding the tracks
    /// unshifted puts the echo in the microphone *before* the reference that
    /// caused it, which no echo canceller can undo, and the run then removes
    /// nothing while returning success.
    nonisolated static func alignReference(
        _ app: [Float], micDelay: TimeInterval, sampleRate: Int,
    ) -> [Float] {
        let shift = Int((micDelay * Double(sampleRate)).rounded())
        if shift > 0 {
            return shift < app.count ? Array(app[shift...]) : []
        }
        if shift < 0 {
            return [Float](repeating: 0, count: -shift) + app
        }
        return app
    }
}

extension PipelineQueue {
    /// Measure, then clean, then report both facts together.
    ///
    /// Cleaning happens before anything reads the track: transcription and the
    /// diarization stage both take `mic_16k.wav`, so this is the one point
    /// where fixing it fixes every consumer at once — including the sidecar a
    /// late re-diarization reads back. Extracted from the transcribe stage,
    /// which is at its function-length cap. Takes the three values it needs
    /// rather than the stage's private job context, so nothing has to widen its
    /// visibility for this.
    func handleEchoBleed(jobID: UUID, appURL: URL, micURL: URL, micDelay: TimeInterval) async {
        guard let echo = await measureEchoBleed(
            jobID: jobID, appURL: appURL, micURL: micURL, micDelay: micDelay,
        ), echo.isAffected else { return }

        var cleaned = false
        if echoCancellationEnabled {
            cleaned = await cancelEcho(
                jobID: jobID, appURL: appURL, micURL: micURL, micDelay: micDelay,
            )
        }
        warnAboutEcho(jobID: jobID, result: echo, cancelled: cleaned)
    }
}
