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
/// The warning is the whole feature on purpose. The app cannot repair the
/// recording after the fact without altering audio, and the user's remedy is
/// both simple and complete: headphones. Reporting it also gives the transcript
/// a reason for the duplicated lines it will contain.
extension PipelineQueue {
    /// Only this much of a recording is analysed. The detector needs enough to
    /// characterise the meeting, not all of it, and reading a two-hour track
    /// whole would add a second large peak next to the one `mix` already makes.
    /// The affected recordings measured so far carry bleed through 34 % to 77 %
    /// of their windows, so the opening minutes show it.
    static let echoBleedAnalysisSeconds = 600.0

    func warnIfEchoBleed(jobID: UUID, appURL: URL, micURL: URL) {
        guard let (app, rate) = Self.loadBounded(appURL),
              let (mic, _) = Self.loadBounded(micURL),
              let result = EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate)
        else { return }

        let percent = Int((result.affectedWindowShare * 100).rounded())
        logger.info(
            "echo_bleed share=\(percent, privacy: .public)% windows=\(result.windowsScored, privacy: .public)",
        )
        guard result.isAffected else { return }

        addWarning(
            id: jobID,
            "Speaker output was picked up by the microphone in \(percent)% of this recording, "
                + "so remote speech may appear twice in the transcript. Using headphones avoids it.",
        )
    }

    /// Reads at most `echoBleedAnalysisSeconds` of a mono file as Float32.
    private static func loadBounded(_ url: URL) -> ([Float], Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = Int(file.processingFormat.sampleRate)
        guard rate > 0 else { return nil }
        let wanted = min(Double(file.length), echoBleedAnalysisSeconds * Double(rate))
        let frames = AVAudioFrameCount(wanted)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer, frameCount: frames)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), rate)
    }
}
