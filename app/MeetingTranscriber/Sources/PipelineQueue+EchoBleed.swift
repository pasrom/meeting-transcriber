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
    static let echoBleedAnalysisSeconds = 600.0

    /// Async, and the work runs off the main actor on purpose. `PipelineQueue`
    /// is `@MainActor`; decoding up to two ten-minute tracks and running the
    /// envelope pass over them synchronously would block the UI for as long as
    /// it takes. Every neighbouring stage awaits for the same reason.
    func warnIfEchoBleed(jobID: UUID, appURL: URL, micURL: URL, micDelay: TimeInterval) async {
        let analysed = Self.echoBleedAnalysisSeconds
        let result = await Task.detached(priority: .utility) { () -> EchoBleedDetector.Result? in
            guard let (app, rate) = Self.loadBounded(appURL, maxSeconds: analysed),
                  let (mic, _) = Self.loadBounded(micURL, maxSeconds: analysed)
            else { return nil }
            return EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate, micDelay: micDelay)
        }.value

        guard let result else { return }
        let percent = Int((result.affectedWindowShare * 100).rounded())
        let scored = result.windowsScored
        let hits = result.windowsAffected
        // Recorded whether or not it fires. A driver, and a field report, must be
        // able to tell "analysed, nothing found" from "never analysed", and a
        // near-miss share is what makes a false negative diagnosable later.
        recordEchoVerdict(
            jobID: jobID,
            EchoDetectionDTO(
                detected: result.isAffected,
                affectedWindowShare: result.affectedWindowShare,
                windowsScored: scored,
                windowsAffected: hits,
            ),
        )
        logger.info("echo_bleed share=\(percent, privacy: .public)% windows=\(scored, privacy: .public) affected=\(hits, privacy: .public)")
        // The per-window series, so a field report is diagnosable with no audio
        // attached. It answers the two questions the share alone cannot: whether
        // a miss sat just under the threshold or nowhere near it, and whether the
        // windows peaked at one stable lag (bleed travels a fixed path) or
        // scattered across the search range (a coincidence). Numbers only — no
        // audio, no transcript, nothing derived from what was said.
        let detail = Self.windowDetail(result.windowScores)
        logger.info("echo_bleed windows=\(detail, privacy: .public)")
        guard result.isAffected else { return }

        // Says what was measured, not more: the share is over the windows that
        // were scored inside the analysed span, which for a long meeting is a
        // fraction of it.
        let analysedSeconds = Double(scored) * EchoBleedDetector.windowSeconds
        let minutes = Int((analysedSeconds / 60).rounded())
        let head = "Speaker output was picked up by the microphone in \(percent)% of the \(minutes) minutes analysed."
        let tail = "Remote speech may appear twice in the transcript. Using headphones avoids it."
        addWarning(id: jobID, "\(head) \(tail)")
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
