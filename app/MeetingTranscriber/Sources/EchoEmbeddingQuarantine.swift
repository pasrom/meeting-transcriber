import Foundation

/// Decides which speaker embeddings from an echo-affected recording may reach
/// the persistent speaker database.
///
/// The reason this exists rather than a warning being enough: `SpeakerMatcher`
/// folds a confirmed embedding into a running-mean centroid and keeps no
/// history, so there is no rollback. A voice learned from contaminated audio is
/// learned permanently, and every later meeting is then matched against it. The
/// transcript of an affected recording is merely wrong; the speaker database is
/// wrong from then on.
///
/// On a recording where the loudspeaker output came back through the microphone,
/// the microphone track's embeddings were computed over audio that provably
/// carries somebody else's voice. Those are the ones held back. The app track is
/// untouched by the bleed and stays admissible, so a remote participant named on
/// an affected recording is still learned.
///
/// This gates only what is *written*. Naming still relabels the transcript, and
/// matching against already-known voices still runs: reading a contaminated
/// embedding costs one wrong suggestion the user can correct, writing one costs
/// every future meeting.
enum EchoEmbeddingQuarantine {
    /// The subset of `embeddings` that may update the speaker database.
    ///
    /// Anything but `affected` lets everything through, including
    /// `notMeasured`: a recording nobody analysed must behave exactly as it did
    /// before this existed.
    static func admissible(
        _ embeddings: [String: [Float]],
        verdict: EchoVerdict,
        isDualSource: Bool,
    ) -> [String: [Float]] {
        guard verdict == .affected, isDualSource else { return embeddings }

        // Normally the dual-track merge has prefixed every key with its track,
        // so the microphone's speakers are named and can be dropped by name.
        let tracks = Set(embeddings.keys.map { SpeakerKey(encoded: $0).track })
        if tracks.contains(.mic) || tracks.contains(.app) {
            return embeddings.filter { SpeakerKey(encoded: $0.key).track != .mic }
        }

        // No key carries a track, yet the job was dual-source: one track's
        // diarization failed and the pipeline fell back to the other one alone,
        // which leaves the surviving labels unprefixed. Which track survived is
        // not recoverable from here, and one of the two possibilities is the
        // microphone — in which case every embedding is contaminated. Hold all
        // of them. The cost when the app track was the survivor is one missed
        // enrollment opportunity, on a recording already known to be damaged;
        // the cost of guessing wrong the other way is permanent.
        return [:]
    }
}
