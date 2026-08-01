import Foundation

/// Why a run could not be claimed, or that it was.
enum RunClaim: Equatable {
    case claimed
    /// This very job is already running. Whoever owns it will report under the
    /// same job ID, so a caller can drop its copy without leaving a trace.
    case refusedSameJob
    /// A different job is already running this audio. Nobody will ever report
    /// under this job's ID, so a caller owes it an answer of its own.
    case refusedSameAudio
}

/// Process-wide record of which pipeline runs are currently executing, so a
/// second run of the same recording cannot start while the first is still
/// going.
///
/// A `PipelineQueue` guards its own re-entry with `isProcessing`, but that flag
/// only ever covers one instance. When a replacement queue is built while the
/// previous one is still working, the two know nothing of each other, both read
/// the same snapshot file, and both can start the same job. Issue #558 is what
/// that costs.
///
/// A claim carries two identities because either one can be the only thing two
/// runs have in common: the job ID for a job restored from the snapshot, and the
/// audio path for a recording that orphan recovery rebuilds under a fresh job
/// ID. Paths are standardized so the same file reached by a different spelling
/// is recognised as one claim, matching how the orphan scan and the processed
/// ledger compare paths. The two are stored together rather than side by side,
/// so a release cannot name a different path than the claim did and strand it.
///
/// Only the mix path counts as the audio identity. A paired import carries no
/// mix file, so two separate enqueues of the same app plus mic pair rest on the
/// job ID alone and would not recognise each other. Accepted: the orphan scan
/// cannot rebuild such a group either, so the fresh-ID route that motivates the
/// path identity does not reach them.
///
/// Held only in memory: a claim describes a run inside this process, so every
/// launch legitimately starts with none. Two instances of the app running
/// against the same data directory are therefore not covered by this at all.
@MainActor
final class InFlightRunRegistry {
    static let shared = InFlightRunRegistry()

    /// Claimed job IDs, each mapped to the audio path claimed with it. Jobs
    /// without a mix file map to nil and rest on the ID alone.
    private var claims: [UUID: String?] = [:]

    /// The claimed audio paths, standardized. Callers filtering a whole batch
    /// take this once on the main actor rather than asking per candidate, since
    /// the scan they filter runs off it.
    var claimedAudioPaths: Set<String> {
        Set(claims.values.compactMap(\.self))
    }

    /// Claim a run for the caller, or say which identity is already spoken for.
    func begin(jobID: UUID, mixPath: URL?) -> RunClaim {
        guard claims[jobID] == nil else { return .refusedSameJob }
        let audioKey = mixPath.map(Self.key)
        if let audioKey, claimedAudioPaths.contains(audioKey) { return .refusedSameAudio }
        claims[jobID] = .some(audioKey)
        return .claimed
    }

    /// Release a claim, including whatever audio path it was made with. Safe to
    /// call for a run that never claimed.
    func end(jobID: UUID) {
        claims.removeValue(forKey: jobID)
    }

    func isInFlight(jobID: UUID) -> Bool {
        claims[jobID] != nil
    }

    func isInFlight(mixPath: URL) -> Bool {
        claimedAudioPaths.contains(Self.key(mixPath))
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
