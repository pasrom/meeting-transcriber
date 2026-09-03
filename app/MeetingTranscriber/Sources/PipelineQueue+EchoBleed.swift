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
/// What the transcribe stage carries from the detector pass to the segment
/// classification: the verdict everything is gated on, and the per-window
/// scores whose lags say where the two tracks actually match. The scores stay
/// in memory rather than on the job on purpose — they grow with the recording,
/// and the wire shape (`EchoDetectionDTO`) deliberately leaves them behind.
struct EchoBleedAnalysis {
    let verdict: EchoVerdict
    let windowScores: [EchoBleedDetector.WindowScore]
    /// Share of scored windows that carried bleed, and how many were scored.
    /// Only meaningful on an `.affected` analysis, which is the only one the
    /// announcement says anything about.
    let affectedPercent: Int
    let windowsScored: Int

    init(
        verdict: EchoVerdict,
        windowScores: [EchoBleedDetector.WindowScore] = [],
        affectedPercent: Int = 0,
        windowsScored: Int = 0,
    ) {
        self.verdict = verdict
        self.windowScores = windowScores
        self.affectedPercent = affectedPercent
        self.windowsScored = windowsScored
    }
}

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
    /// `EchoVerdict` from `job.echo`. The return carries the verdict for a
    /// caller that need not re-read the job, plus the per-window scores the
    /// segment classification aligns with; those exist only here, since the
    /// recorded DTO deliberately drops the series.
    func measureEchoBleed(jobID: UUID, appURL: URL, micURL: URL, micDelay: TimeInterval) async -> EchoBleedAnalysis {
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

        guard let result else { return EchoBleedAnalysis(verdict: .notMeasured) }
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
        guard result.isAffected else { return EchoBleedAnalysis(verdict: .clean, windowScores: result.windowScores) }
        return EchoBleedAnalysis(
            verdict: .affected, windowScores: result.windowScores,
            // Carried rather than recomputed later: the announcement says what
            // was measured, and the two numbers it says it by have to be the
            // ones the verdict came from.
            affectedPercent: Int((result.affectedWindowShare * 100).rounded()),
            windowsScored: scored,
        )
    }

    /// Tells the user what the measurement found, once the remedy has had its
    /// turn. Split from the measurement because the sentence in the middle
    /// depends on what actually happened afterwards: promising that the far end
    /// was removed, before the run that removes it, would be a claim the app
    /// cannot keep when the model is missing or the canceller throws.
    func announceEchoBleed(_ analysis: EchoBleedAnalysis, jobID: UUID, echoRemoved: Bool) {
        guard analysis.verdict == .affected else { return }
        // Says what was measured, not more: the share is over the windows that
        // were scored inside the analysed span, which for a long meeting is a
        // fraction of it.
        let analysedSeconds = Double(analysis.windowsScored) * EchoBleedDetector.windowSeconds
        let minutes = Int((analysedSeconds / 60).rounded())
        // "1 minutes" is reachable: the minimum firing configuration is three
        // ten-second windows, and the E2E fixture produces four.
        let span = minutes == 1 ? "minute" : "minutes"
        let head = "Speaker output was picked up by the microphone in \(analysis.affectedPercent)% of the \(minutes) \(span) analysed."
        let tail = echoRemoved
            ? "It was removed from the microphone track before transcription. Headphones still give the cleaner recording."
            : "Remote speech may appear twice in the transcript. Using headphones avoids it."
        // Third sentence because the consequence is otherwise invisible: naming
        // speakers on this recording will look like it worked and teach the app
        // nothing. Saying so here is honest — the quarantine follows from this
        // same verdict, so it is a statement of fact rather than a prediction.
        // Unchanged by cancellation on purpose: the quarantine is a safety
        // measure, and lifting it on a repair that has never been watched in
        // the field is exactly the trade this project keeps refusing.
        let db = "Voices from this recording are not added to the speaker database."
        addWarning(id: jobID, "\(head) \(tail) \(db)")
    }

    /// Per microphone segment: is it the loudspeaker coming back?
    ///
    /// Only runs on a recording the detector already called affected. Removing
    /// transcript lines is a visible edit, so it is tied to the verdict the user
    /// was told about rather than applied on any recording that happens to
    /// correlate. The known cost: a recording too short for a verdict keeps its
    /// duplicates, which is the same span where the warning stays silent.
    ///
    /// Loads the two tracks a second time rather than sharing the detector's
    /// copy. The stage it sits in runs two Whisper passes, so a bounded decode
    /// beside them does not register, and threading megabytes of samples from a
    /// detached task through the actor to keep them alive would cost more than
    /// it saves.
    func classifyMicEcho(
        remedy: EchoRemedy,
        analysis: EchoBleedAnalysis,
        // One argument, the way the neighbouring dual-track diarization call
        // already spells the same three: they are never meaningful apart, and
        // apart they were the fifth, sixth and seventh things a reader had to
        // keep in order at the call site.
        tracks: (app: URL, mic: URL, micDelay: TimeInterval),
        micSegments: [TimestampedSegment],
    ) async -> [EchoSegmentVerdict] {
        // The remedy, not the setting: with cancellation on there is nothing
        // here to find, because the far end is already out of the audio these
        // segments were transcribed from, and this measure was calibrated on
        // audio that still had it.
        guard remedy == .transcriptDedup, analysis.verdict == .affected, !micSegments.isEmpty else { return [] }
        let delay = AudioMixer.clampMicDelay(tracks.micDelay)
        let windowScores = analysis.windowScores
        return await Task.detached(priority: .utility) { () -> [EchoSegmentVerdict] in
            let analysed = Self.echoBleedAnalysisSeconds
            guard let (app, appRate) = Self.loadBounded(tracks.app, maxSeconds: analysed),
                  let (mic, micRate) = Self.loadBounded(tracks.mic, maxSeconds: analysed),
                  appRate == micRate
            else {
                logger.warning("echo_dedup skipped: tracks unreadable or at different rates")
                return []
            }
            return EchoSegmentClassifier.classify(
                app: app, mic: mic, sampleRate: appRate, micDelay: delay,
                micSegments: micSegments, windowScores: windowScores,
            )
        }.value
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
