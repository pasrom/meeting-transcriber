import AudioTapLib
import Foundation

/// The mute times of a recording still in progress, on disk beside its tracks.
///
/// `stop()` hands them over in `RecordingResult` and removes the file, so one
/// still here means the recording never stopped. The audio itself is already
/// silent either way: this is what lets a recovered job explain and filter it.
enum MicMuteLog {
    private static func url(stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(stem + RecordingFileSuffix.micMuteLog)
    }

    static func write(_ timeline: MicMuteTimeline, stem: String, in dir: URL) {
        let file = url(stem: stem, in: dir)
        guard let data = try? JSONEncoder().encode(timeline),
              (try? data.write(to: file, options: .atomic)) != nil else { return }

        try? FileManager.default.restrictToOwner(file)
    }

    static func remove(stem: String, in dir: URL) {
        try? FileManager.default.removeItem(at: url(stem: stem, in: dir))
    }

    /// Remove the log of the recording whose mix was at `mix`, a file named
    /// `<stem>_mix.wav`. For the moment that mix leaves the staging folder: a
    /// recovered recording keeps its log until then, and the orphan scan
    /// leaves a log without a mix alone, so nothing else would delete it.
    static func remove(besideMix mix: URL) {
        let name = mix.lastPathComponent
        guard name.hasSuffix(RecordingFileSuffix.mix) else { return }
        remove(stem: String(name.dropLast(RecordingFileSuffix.mix.count)), in: mix.deletingLastPathComponent())
    }

    /// The intervals a crashed recording left, with a mute still open running to
    /// the end of `micTrack`. Empty when there is no log or no mic track: on any
    /// other track they would silence the far end. Leaves the file for `remove`.
    static func recoveredIntervals(stem: String, in dir: URL, micTrack: URL?) -> [MicMuteInterval] {
        guard let track = micTrack,
              let data = try? Data(contentsOf: url(stem: stem, in: dir)),
              let timeline = try? JSONDecoder().decode(MicMuteTimeline.self, from: data) else { return [] }

        let duration = Double(AudioMixer.frameCount(of: track)) / Double(AudioConstants.targetSampleRate)
        return timeline.intervals(endingAt: duration)
    }

    typealias RecoveryCandidate = (group: PairedRecordingResolver.Group, micMuted: [MicMuteInterval])

    /// For the orphan scan: the mute times of each group it will recover, and the
    /// log of every finished stem it skips deleted, since nothing reads it again.
    /// A stem with no mix yet may still be recording, so its log is left alone.
    /// So is one whose mix is in `accountedForMixPaths` (standardized paths, as
    /// the scan keys them): a job or a run has that recording, but a job is on
    /// disk only once its snapshot write lands, and a process that dies before
    /// then recovers the recording again and reads the log again. That log
    /// goes when the recording leaves staging.
    static func forRecovery(
        _ recoverable: [PairedRecordingResolver.Group], among entries: [URL], in dir: URL,
        keepingLogsOf accountedForMixPaths: Set<String>,
    ) -> [RecoveryCandidate] {
        let recoverableStems = Set(recoverable.map(\.stem))
        var mixPathByStem: [String: String] = [:]
        var logStems: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasSuffix(RecordingFileSuffix.mix) {
                mixPathByStem[String(name.dropLast(RecordingFileSuffix.mix.count))] = entry.standardizedFileURL.path
            } else if name.hasSuffix(RecordingFileSuffix.micMuteLog) {
                logStems.append(String(name.dropLast(RecordingFileSuffix.micMuteLog.count)))
            }
        }
        for stem in logStems {
            guard let mixPath = mixPathByStem[stem], !recoverableStems.contains(stem),
                  !accountedForMixPaths.contains(mixPath) else { continue }
            remove(stem: stem, in: dir)
        }
        return recoverable.map { ($0, recoveredIntervals(stem: $0.stem, in: dir, micTrack: $0.mic)) }
    }
}
