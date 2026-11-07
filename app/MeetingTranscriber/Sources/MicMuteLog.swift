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

    /// The intervals a crashed recording left, with a mute still open running to
    /// the end of `track`. Consumes the file. Empty when there is none.
    static func recoveredIntervals(stem: String, in dir: URL, track: URL) -> [MicMuteInterval] {
        let file = url(stem: stem, in: dir)
        guard let data = try? Data(contentsOf: file),
              let timeline = try? JSONDecoder().decode(MicMuteTimeline.self, from: data) else { return [] }

        try? FileManager.default.removeItem(at: file)
        let duration = Double(AudioMixer.frameCount(of: track)) / Double(AudioConstants.targetSampleRate)
        return timeline.intervals(endingAt: duration)
    }
}

extension MicMuteInterval {
    /// Bracketed like the recording note, so it cannot read as something said.
    var transcriptMarker: String {
        "[Mic muted \(TimestampedSegment.clockTime(start))–\(TimestampedSegment.clockTime(end))]"
    }
}

extension [MicMuteInterval] {
    func shifted(by offset: TimeInterval) -> [MicMuteInterval] {
        map { MicMuteInterval(start: $0.start + offset, end: $0.end + offset) }
    }

    func mutedFrames(rate: Int) -> Int {
        Int(reduce(0) { $0 + $1.end - $1.start } * Double(rate))
    }
}

extension [TimestampedSegment] {
    /// Drops text timed mostly inside a muted stretch. Only "mostly", because a
    /// sentence that ended as the user muted still holds words that were recorded.
    func removingMuted(_ intervals: [MicMuteInterval]) -> [TimestampedSegment] {
        guard !intervals.isEmpty else { return self }

        return filter { segment in
            let muted = intervals.reduce(0) { total, interval in
                total + Swift.max(0, Swift.min(segment.end, interval.end) - Swift.max(segment.start, interval.start))
            }
            return muted * 2 <= segment.end - segment.start
        }
    }
}
