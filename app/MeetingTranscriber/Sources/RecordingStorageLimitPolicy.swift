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

/// Decides what the storage limit does on one pass. Pure: sizes, dates and the
/// recordings that may be deleted are passed in.
enum RecordingStorageLimitPolicy {
    /// Time between the "limit reached" notification and the first delete.
    static let gracePeriod: TimeInterval = 24 * 3600

    /// One recording the age rules would let go of, with what its files weigh.
    struct Candidate: Equatable {
        let jobID: UUID
        let recordedAt: Date
        let urls: [URL]
        let bytes: Int64
    }

    enum Step: Equatable {
        /// Under the limit or switched off: forget any earlier warning.
        case clear
        /// Newly over the limit: tell the user and start the grace period.
        case warn
        /// Over the limit, still within the grace period.
        case wait
        /// Over the limit and the grace period is over.
        case delete
    }

    static func step(
        totalBytes: Int64, settings: RecordingStorageLimitSettings, exceededSince: Date?, now: Date,
    ) -> Step {
        guard settings.enabled, totalBytes > settings.limitBytes else { return .clear }
        guard let exceededSince else { return .warn }
        return now >= exceededSince.addingTimeInterval(gracePeriod) ? .delete : .wait
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
}

/// When the recordings first went over the limit, kept across launches so a
/// restart neither repeats the notification nor restarts the grace period.
struct RecordingStorageAlarm {
    let load: () -> Date?
    let save: (Date?) -> Void

    static let key = "recordingStorageLimitExceededSince"

    static func defaults(_ defaults: UserDefaults) -> Self {
        Self(load: { defaults.object(forKey: key) as? Date }, save: { defaults.set($0, forKey: key) })
    }

    /// Held in memory only, for tests.
    static func inMemory() -> Self {
        final class Box { var date: Date? }
        let box = Box()
        return Self(load: { box.date }, save: { box.date = $0 })
    }
}
