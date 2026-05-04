import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerMatcher")

extension SpeakerMatcher {
    /// Forensic log for a single label match decision. Names are
    /// SHA-256-pseudonymized via `String.pseudonymized` so the log can be
    /// shared in bug reports without leaking real speaker names. Distances
    /// and margins are public; the per-label classifier ID is public too.
    static func logMatchDecision(
        label: String,
        best: TopCandidate?,
        second: TopCandidate?,
        assigned: String,
        thresholds: (distance: Float, margin: Float),
    ) {
        guard let best else {
            logger.info(
                "speaker_match label=\(label, privacy: .public) result=no_candidates",
            )
            return
        }
        let bestPseudo = best.name.pseudonymized
        let secondPseudo = second?.name.pseudonymized ?? "none"
        let secondDist = second?.hybrid ?? .greatestFiniteMagnitude
        let actualMargin = secondDist - best.hybrid

        if assigned == best.name {
            logger.info(
                "speaker_match_assigned label=\(label, privacy: .public) speaker=\(bestPseudo, privacy: .public) bestDist=\(best.hybrid, privacy: .public) secondDist=\(secondDist, privacy: .public) margin=\(actualMargin, privacy: .public)",
            )
        } else if best.hybrid >= thresholds.distance {
            logger.info(
                "speaker_match_rejected label=\(label, privacy: .public) reason=above_threshold dist=\(best.hybrid, privacy: .public) threshold=\(thresholds.distance, privacy: .public) candidate=\(bestPseudo, privacy: .public)",
            )
        } else {
            logger.info(
                "speaker_match_rejected label=\(label, privacy: .public) reason=below_margin margin=\(actualMargin, privacy: .public) min=\(thresholds.margin, privacy: .public) candidate=\(bestPseudo, privacy: .public) runner_up=\(secondPseudo, privacy: .public)",
            )
        }
    }
}
