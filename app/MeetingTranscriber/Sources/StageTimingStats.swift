import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "StageTimingStats")

/// A pipeline stage whose wall-clock duration we track. Raw values match the
/// corresponding `JobState` cases so the menu can look an average up by state.
enum StageKind: String, Codable, CaseIterable {
    case transcribing
    case diarizing
    case generatingProtocol

    var label: String {
        switch self {
        case .transcribing: "Transcribing"
        case .diarizing: "Diarizing"
        case .generatingProtocol: "Protocol"
        }
    }

    /// The timed stage a `JobState` corresponds to, or nil for non-timed states
    /// (`.waiting`, `.speakerNamingPending`, `.done`, `.error`). The speaker-
    /// naming wait is its own state, so its human-paced duration is never
    /// attributed to diarization.
    init?(jobState: JobState) {
        switch jobState {
        case .transcribing: self = .transcribing
        case .diarizing: self = .diarizing
        case .generatingProtocol: self = .generatingProtocol
        default: return nil
        }
    }
}

/// One row in the JSONL stage-timing log: how long a single pipeline stage of a
/// single job took, plus the audio length it processed so a real-time factor is
/// derivable. `engine` / `diarizerMode` are context tags that make averages
/// comparable (a Sortformer diarization is not the same cost as an offline one).
struct StageTimingEvent: Codable, Equatable {
    let ts: Date
    let jobID: UUID
    let stage: StageKind
    let wallClockSeconds: Double
    /// Seconds of audio the stage processed (last segment end). 0 when unknown.
    let audioSeconds: Double
    let engine: String?
    let diarizerMode: String?
}

enum StageTimingStats {
    /// Aggregate of one stage over a set of events.
    struct StageAggregate: Equatable {
        let stage: StageKind
        let count: Int
        /// Mean wall-clock duration — the intuitive "how long does it usually
        /// take" number shown in the menu and Settings.
        let avgWallClockSeconds: Double
        /// Average real-time factor = processing-seconds per second of audio,
        /// computed as a ratio of totals (sum of wall-clock over sum of audio)
        /// so a long meeting weighs more than a short one — the right basis for
        /// "how long will THIS meeting take". `nil` when no event carried a
        /// positive audio duration (can't normalise).
        let avgRTF: Double?
    }

    /// Group events by stage and compute per-stage count / average wall-clock /
    /// average RTF. Events whose `audioSeconds <= 0` still count toward
    /// `count` and `avgWallClockSeconds` but are excluded from the RTF ratio so
    /// they neither divide by zero nor skew throughput.
    static func aggregate(events: [StageTimingEvent]) -> [StageKind: StageAggregate] {
        var byStage: [StageKind: [StageTimingEvent]] = [:]
        for e in events {
            byStage[e.stage, default: []].append(e)
        }
        return byStage.mapValues { stageEvents in
            let count = stageEvents.count
            let avgWall = stageEvents.reduce(0.0) { $0 + $1.wallClockSeconds } / Double(count)
            let withAudio = stageEvents.filter { $0.audioSeconds > 0 }
            let avgRTF: Double?
            if withAudio.isEmpty {
                avgRTF = nil
            } else {
                let totalWall = withAudio.reduce(0.0) { $0 + $1.wallClockSeconds }
                let totalAudio = withAudio.reduce(0.0) { $0 + $1.audioSeconds }
                avgRTF = totalWall / totalAudio
            }
            return StageAggregate(
                stage: stageEvents[0].stage, count: count,
                avgWallClockSeconds: avgWall, avgRTF: avgRTF,
            )
        }
    }
}

/// Append-only JSONL writer for stage-timing events. One file per app install,
/// owner-readable (chmod 0600 on first creation). Production callers use the
/// no-arg `init()`; tests pass an explicit `path:` to avoid polluting the real
/// log. Mirrors `RecognitionStatsLog`.
actor StageTimingLog {
    static let defaultPath = AppPaths.dataDir.appendingPathComponent("stage_timing.jsonl")

    private let path: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(path: URL = StageTimingLog.defaultPath) {
        self.path = path
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ events: [StageTimingEvent]) {
        guard !events.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            )

            if !FileManager.default.fileExists(atPath: path.path) {
                FileManager.default.createFile(
                    atPath: path.path, contents: nil,
                    attributes: [.posixPermissions: 0o600],
                )
            }

            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            for event in events {
                let line = try encoder.encode(event) + Data([0x0A])
                try handle.write(contentsOf: line)
            }
            try handle.synchronize()
        } catch {
            logger.error("Failed to append stage-timing events: \(error.localizedDescription)")
        }
    }

    /// Load events with `ts` within the last `interval` seconds. Skips lines that
    /// fail to decode (forward-compat for future schema changes).
    func loadRecent(within interval: TimeInterval, now: Date = Date()) -> [StageTimingEvent] {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = now.addingTimeInterval(-interval)
        var out: [StageTimingEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(StageTimingEvent.self, from: lineData),
                  event.ts >= cutoff else { continue }
            out.append(event)
        }
        return out
    }
}
