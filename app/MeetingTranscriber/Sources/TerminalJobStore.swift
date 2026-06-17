import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "TerminalJobStore")

/// File-backed store of recent finished-job statuses, keyed by jobID with a
/// bounded FIFO so it can't grow without limit.
///
/// `PipelineQueue` removes `.done` jobs from its in-memory list after
/// `completedJobLifetime` (default 60s). An automation client polling slower
/// than that would then get a 404 and lose the transcript/protocol paths. This
/// store outlives the reaping (and an app restart) so `GET /v1/jobs/<id>` stays
/// answerable. Only finished (`.done`/`.error`) jobs are ever recorded; the
/// element type is the same `JobStatusDTO` served on the wire.
///
/// Writes are atomic (staging file + `replaceItemAt`, mirroring
/// `PipelineSnapshot`) and owner-only; reads happen on `init`.
@MainActor
final class TerminalJobStore {
    private let path: URL
    private let cap: Int
    private(set) var records: [JobStatusDTO]

    init(path: URL, cap: Int = 200) {
        self.path = path
        self.cap = cap
        self.records = Self.load(from: path)
    }

    /// Pure: drop any record with the same jobID, append the new one, and keep
    /// only the most recent `cap` entries.
    nonisolated static func upserting(
        _ records: [JobStatusDTO], with rec: JobStatusDTO, cap: Int,
    ) -> [JobStatusDTO] {
        var next = records.filter { $0.jobID != rec.jobID }
        next.append(rec)
        if next.count > cap {
            next = Array(next.suffix(cap))
        }
        return next
    }

    /// Upsert `rec` and persist. Best-effort: a write failure is logged but
    /// never throws into the pipeline (the job itself already succeeded).
    func record(_ rec: JobStatusDTO) {
        records = Self.upserting(records, with: rec, cap: cap)
        save()
    }

    func lookup(jobID: UUID) -> JobStatusDTO? {
        records.last { $0.jobID == jobID.uuidString }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            let staging = path.deletingLastPathComponent()
                .appendingPathComponent(path.lastPathComponent + ".tmp")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try data.write(to: staging)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: staging)
            // Records carry meeting titles + output paths — keep owner-only,
            // matching the other sensitive-JSON writers (SpeakerMatcher,
            // RecordingSidecar).
            try? FileManager.default.restrictToOwner(path)
        } catch {
            logger.error("Failed to persist terminal job records: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load records from `path`, returning `[]` on a missing or unreadable file
    /// (a corrupt store must never block startup or readback).
    private static func load(from path: URL) -> [JobStatusDTO] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        do {
            let data = try Data(contentsOf: path)
            return try JSONDecoder().decode([JobStatusDTO].self, from: data)
        } catch {
            logger.error("Failed to load terminal job records: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
