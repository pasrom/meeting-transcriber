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
    /// `EchoVerdict` from `job.echo`. Returned as well purely so a caller that
    /// wants it need not re-read the job.
    @discardableResult
    func warnIfEchoBleed(jobID: UUID, appURL: URL, micURL: URL, micDelay: TimeInterval) async -> EchoVerdict {
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

        guard let result else { return .notMeasured }
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
        guard result.isAffected else { return .clean }

        // Says what was measured, not more: the share is over the windows that
        // were scored inside the analysed span, which for a long meeting is a
        // fraction of it.
        let analysedSeconds = Double(scored) * EchoBleedDetector.windowSeconds
        let minutes = Int((analysedSeconds / 60).rounded())
        // "1 minutes" is reachable: the minimum firing configuration is three
        // ten-second windows, and the E2E fixture produces four.
        let span = minutes == 1 ? "minute" : "minutes"
        let head = "Speaker output was picked up by the microphone in \(percent)% of the \(minutes) \(span) analysed."
        let tail = "Remote speech may appear twice in the transcript. Using headphones avoids it."
        // Third sentence because the consequence is otherwise invisible: naming
        // speakers on this recording will look like it worked and teach the app
        // nothing. Saying so here is honest — the quarantine follows from this
        // same verdict, so it is a statement of fact rather than a prediction.
        let db = "Voices from this recording are not added to the speaker database."
        addWarning(id: jobID, "\(head) \(tail) \(db)")
        return .affected
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
    /// Removes the loudspeaker echo from the 16 kHz microphone track, in place.
    ///
    /// **Overwriting `mic_16k.wav` is the design, not a shortcut.** Transcription,
    /// the dual-track diarization, and the `<slug>_mic_16k.wav` sidecar that late
    /// re-diarization reads back all take that one path. Writing the cleaned
    /// audio anywhere else would leave the first pass and every later pass
    /// disagreeing about what the microphone heard, and the phantom speaker
    /// would come back the moment someone reopened naming. The raw `_mic.wav`
    /// the recorder produced is untouched, so nothing is lost.
    ///
    /// Returns whether the track was replaced. Every failure is soft: the
    /// recording stays exactly as it was and the detector's warning still
    /// stands, which is the behaviour before this existed.
    func cancelEcho(jobID: UUID, appURL: URL, micURL: URL) async -> Bool {
        guard let modelPath = await EchoCancellerModel.ensureAvailable() else {
            logger.warning("echo_cancel_skipped: weights unavailable")
            return false
        }
        let applied = await Task.detached(priority: .utility) { () -> Bool in
            guard let canceller = EchoCanceller(modelPath: modelPath) else { return false }
            do {
                // Whole-track, matching the two `resampleFile` calls that just
                // ran on the same audio: this pipeline already holds both
                // tracks in memory at this point, so streaming in chunks would
                // add a continuity question without changing the peak.
                let reference = try AudioMixer.loadAudioFileAsFloat32(url: appURL)
                let mic = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
                let cleaned = try canceller.process(mic: mic, reference: reference)
                try AudioMixer.saveWAV(
                    samples: cleaned, sampleRate: AudioConstants.targetSampleRate, url: micURL,
                )
                return true
            } catch {
                logger.error("echo_cancel_failed \(error.localizedDescription, privacy: .public)")
                return false
            }
        }.value
        if applied {
            recordEchoCancelled(jobID: jobID)
            logger.info("echo_cancel_applied")
        }
        return applied
    }
}
