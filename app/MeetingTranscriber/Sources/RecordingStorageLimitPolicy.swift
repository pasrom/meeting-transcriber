import Foundation

/// The storage-limit settings, read together on every pass.
struct RecordingStorageLimitSettings: Equatable {
    let enabled: Bool
    let limitBytes: Int64

    static let off = Self(enabled: false, limitBytes: 0)

    static func gigabytes(_ gigabytes: Int, enabled: Bool) -> Self {
        Self(enabled: enabled, limitBytes: Int64(gigabytes) * 1_000_000_000)
    }
}

/// The warning the user was given when the recordings went over the limit:
/// when, under which limit, and for which output folder. It covers only the
/// recordings already deletable when it was given, under a limit at least as
/// low, in that folder.
struct RecordingStorageWarning: Codable, Equatable {
    let since: Date
    let limitBytes: Int64
    /// `RecordingRetentionPolicy.pathKey` of the pass's scope root, nil when
    /// the pass counts every root.
    let root: String?

    /// The first moment a recording it covers may be deleted. Wall-clock
    /// time: a pass after a long quit deletes at once.
    var deletesFrom: Date {
        since.addingTimeInterval(RecordingStorageLimitPolicy.gracePeriod)
    }

    func covers(limitBytes: Int64, root: String?) -> Bool {
        limitBytes >= self.limitBytes && root == self.root
    }

    /// By when the recording became deletable, not when it was made: one
    /// whose notes are saved later, after a retry say, gets its own warning.
    func covers(_ candidate: RecordingStorageLimitPolicy.Candidate) -> Bool {
        candidate.eligibleAt <= since
    }
}

/// Decides what the storage limit does on one pass. Pure: sizes, dates and the
/// recordings that may be deleted are passed in.
enum RecordingStorageLimitPolicy {
    /// Time between the "limit reached" notification and the first delete.
    static let gracePeriod: TimeInterval = 24 * 3600

    /// One recording the age rules would let go of, with what its files weigh.
    struct Candidate: Equatable {
        let jobID: UUID
        let recordedAt: Date
        /// When its outputs were saved, so it became deletable.
        let eligibleAt: Date
        let urls: [URL]
        let bytes: Int64
    }

    enum Step: Equatable {
        /// Under the limit or switched off: forget any earlier warning.
        case clear
        /// Over the limit with no warning that covers it: tell the user and
        /// start the grace period.
        case warn
        /// Over the limit, still within the grace period.
        case wait
        /// Over the limit and the grace period is over.
        case delete
    }

    /// A stored warning counts only for a limit at least as low as the one it
    /// named and for the same folder; a lower limit or another folder warns again.
    static func step(
        totalBytes: Int64, settings: RecordingStorageLimitSettings, warning: RecordingStorageWarning?,
        root: String?, now: Date,
    ) -> Step {
        guard settings.enabled, totalBytes > settings.limitBytes else { return .clear }
        guard let warning, warning.covers(limitBytes: settings.limitBytes, root: root) else { return .warn }
        return now >= warning.deletesFrom ? .delete : .wait
    }

    /// The oldest candidates whose removal brings `totalBytes` to the limit or
    /// below, or every candidate when even that is not enough.
    static func selectForDeletion(
        _ candidates: [Candidate], totalBytes: Int64, limitBytes: Int64,
    ) -> [Candidate] {
        var remaining = totalBytes
        var picked: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            guard remaining > limitBytes else { break }
            picked.append(candidate)
            remaining -= candidate.bytes
        }
        return picked
    }

    /// After a delete that still leaves the total over the limit: warn again
    /// when a recording the warning does not cover could go, so it is never
    /// deleted without a warning given after it became deletable.
    static func needsNewWarning(
        remainingBytes: Int64, limitBytes: Int64, uncovered: [Candidate],
    ) -> Bool {
        remainingBytes > limitBytes && !uncovered.isEmpty
    }
}

/// The stored warning, kept across launches so a restart neither repeats the
/// notification nor restarts the grace period.
struct RecordingStorageAlarm {
    let load: () -> RecordingStorageWarning?
    let save: (RecordingStorageWarning?) -> Void

    static let key = "recordingStorageLimitWarning"

    static func defaults(_ defaults: UserDefaults) -> Self {
        Self(
            load: {
                (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode(RecordingStorageWarning.self, from: $0) }
            },
            save: { warning in
                defaults.set(warning.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
            },
        )
    }

    /// Held in memory only, for tests.
    static func inMemory() -> Self {
        final class Box { var warning: RecordingStorageWarning? }
        let box = Box()
        return Self(load: { box.warning }, save: { box.warning = $0 })
    }
}

/// What Settings shows about the storage limit, from the last pass.
struct RecordingStorageStatus: Equatable {
    let totalBytes: Int64
    /// Counted in the total but not deletable now: outputs not written or
    /// missing, in use, or outside the recordings folder.
    let keptBytes: Int64
    let warning: RecordingStorageWarning?
}
