import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecognitionStats")

/// What the user did with the matcher's auto-name suggestion for one speaker label.
enum RecognitionAction: String, Codable, CaseIterable {
    case accepted, corrected, added, skipped, dismissed
}

/// Which diarized track the speaker label belongs to.
enum RecognitionTrack: String, Codable {
    case app, mic, single

    init(label: String) {
        if label.hasPrefix("R_") { self = .app } else if label.hasPrefix("M_") { self = .mic } else { self = .single }
    }
}

/// One row in the JSONL recognition log: a single speaker-label decision.
struct RecognitionEvent: Codable, Equatable {
    let ts: Date
    let jobID: UUID
    let meetingTitle: String
    let track: RecognitionTrack
    let label: String
    let autoName: String?
    let userName: String?
    let action: RecognitionAction
}

enum RecognitionStats {
    /// Maps the (auto, user) pair to a RecognitionAction. Caller passes
    /// `userName == nil` to signal `.dismissed` (timeout / cancel paths).
    static func classify(autoName: String?, userName: String?) -> RecognitionAction {
        let auto = autoName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (auto.isEmpty, user.isEmpty) {
        case (true, true): return .skipped
        case (true, false): return .added
        case (false, true): return .skipped
        case (false, false): return auto == user ? .accepted : .corrected
        }
    }

    /// Build one event per speaker label. Pass `userMapping == nil` to mark all
    /// rows `.dismissed` (timeout / cancel); otherwise rows are classified.
    static func buildEvents(
        suggested: [String: String],
        // swiftlint:disable:next discouraged_optional_collection
        userMapping: [String: String]?,
        jobID: UUID,
        meetingTitle: String,
        now: Date = Date(),
    ) -> [RecognitionEvent] {
        let labels = Set(suggested.keys).union(userMapping?.keys ?? [:].keys).sorted()
        return labels.map { label in
            let auto = nameOrNil(suggested[label], label: label)
            let user = userMapping.flatMap { nameOrNil($0[label], label: label) }
            let action: RecognitionAction = userMapping == nil
                ? .dismissed
                : classify(autoName: auto, userName: user)
            return RecognitionEvent(
                ts: now,
                jobID: jobID,
                meetingTitle: meetingTitle,
                track: RecognitionTrack(label: label),
                label: label,
                autoName: auto,
                userName: user,
                action: action,
            )
        }
    }

    /// `value == label` is the sentinel "no auto-suggestion" (matcher returns the
    /// label as fallback when no speaker matches), so we collapse it to nil.
    private static func nameOrNil(_ value: String?, label: String) -> String? {
        guard let value, !value.isEmpty, value != label else { return nil }
        return value
    }

    struct Aggregate: Equatable {
        let total: Int
        let counts: [RecognitionAction: Int]

        var acceptanceRate: Double {
            guard total > 0 else { return 0 }
            return Double(counts[.accepted] ?? 0) / Double(total)
        }

        var correctionRate: Double {
            guard total > 0 else { return 0 }
            return Double(counts[.corrected] ?? 0) / Double(total)
        }
    }

    static func aggregate(events: [RecognitionEvent], from: Date, to: Date) -> Aggregate {
        let inRange = events.filter { $0.ts >= from && $0.ts <= to }
        var counts: [RecognitionAction: Int] = [:]
        for e in inRange {
            counts[e.action, default: 0] += 1
        }
        return Aggregate(total: inRange.count, counts: counts)
    }
}

/// Append-only JSONL writer for recognition events. One file per app install,
/// owner-readable (chmod 0600 on first creation). Production callers use the
/// no-arg `init()`; tests should pass an explicit `path:` to avoid polluting
/// the user's real log.
actor RecognitionStatsLog {
    static let defaultPath = AppPaths.dataDir.appendingPathComponent("recognition_log.jsonl")

    private let path: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(path: URL = RecognitionStatsLog.defaultPath) {
        self.path = path
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ events: [RecognitionEvent]) {
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
            logger.error("Failed to append recognition events: \(error.localizedDescription)")
        }
    }

    /// Load events with `ts` within the last `interval` seconds. Skips lines that
    /// fail to decode (forward-compat for future schema changes).
    func loadRecent(within interval: TimeInterval, now: Date = Date()) -> [RecognitionEvent] {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = now.addingTimeInterval(-interval)
        var out: [RecognitionEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(RecognitionEvent.self, from: lineData),
                  event.ts >= cutoff else { continue }
            out.append(event)
        }
        return out
    }
}
