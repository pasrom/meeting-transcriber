import AudioTapLib
import Foundation
@testable import MeetingTranscriber

extension RecordingSidecar {
    /// Write the recording sidecar a dual-source recording gets, beside the
    /// staged mix `mix` (`<stem>_mix.wav`), naming its tracks on that stem.
    /// Returns where it was written.
    @discardableResult
    static func writeTestRecordingSidecar(
        besideMix mix: URL, micDelay: TimeInterval = 0.25, muted: [MicMuteInterval] = [],
    ) throws -> URL {
        guard let url = recordingSidecarURL(besideMix: mix),
              let stem = RecordingFileSuffix.stripSuffix(from: mix.lastPathComponent)?.stem
        else { throw CocoaError(.fileNoSuchFile) }
        try RecordingSidecar(
            title: "Weekly Sync", appName: "Teams", startedAt: Date(), stoppedAt: Date(),
            participants: [], micDelaySeconds: micDelay, trigger: .auto,
            mixFilename: stem + RecordingFileSuffix.mix, appFilename: stem + RecordingFileSuffix.app,
            micFilename: stem + RecordingFileSuffix.mic, micMuteIntervals: muted,
        ).write(to: url)
        return url
    }
}
