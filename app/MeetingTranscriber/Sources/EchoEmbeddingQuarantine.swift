import AVFoundation
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
    /// `provenSilentAppTrack` names microphone speakers that did their talking
    /// while the app track carried nothing at all. Those are admissible even on
    /// an affected recording: where nothing was playing, nothing can have bled
    /// through. Empty means "no such evidence", which falls back to holding the
    /// whole microphone track — the behaviour before this evidence existed.
    static func admissible(
        _ embeddings: [String: [Float]],
        verdict: EchoVerdict,
        isDualSource: Bool,
        provenSilentAppTrack: Set<String> = [],
    ) -> [String: [Float]] {
        guard verdict == .affected, isDualSource else { return embeddings }

        // Normally the dual-track merge has prefixed every key with its track,
        // so the microphone's speakers are named and can be dropped by name.
        let tracks = Set(embeddings.keys.map { SpeakerKey(encoded: $0).track })
        if tracks.contains(.mic) || tracks.contains(.app) {
            return embeddings.filter { entry in
                SpeakerKey(encoded: entry.key).track != .mic
                    || provenSilentAppTrack.contains(entry.key)
            }
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

/// Decides which microphone speakers spoke only while the app track was silent.
///
/// Deliberately strict, because the two mistakes cost wildly different amounts:
/// wrongly admitting an embedding folds a stranger's voice into a running-mean
/// centroid that has no history and poisons every later meeting, while wrongly
/// holding one costs a re-enrollment. So the test is near-digital silence over
/// almost all of a speaker's talking time, and anything short of that falls back
/// to holding the track.
enum AppTrackSilence {
    /// Below this the app track is carrying nothing anyone could hear, let alone
    /// bleed. Far below speech; well above the numerical noise of a resample.
    static let silentDBFS = -60.0
    /// How much of a speaker's talking time has to fall in silent stretches.
    static let requiredShare = 0.8

    /// `nil` when the app track cannot be read: no evidence, so no admission.
    static func micSpeakersProvenClean(
        segments: [PipelineQueue.SpeakerNamingData.Segment], appTrackURL: URL,
    ) -> Set<String> {
        guard let file = try? AVAudioFile(forReading: appTrackURL) else { return [] }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return [] }

        var silentTime: [String: TimeInterval] = [:]
        var totalTime: [String: TimeInterval] = [:]
        for segment in segments where SpeakerKey(encoded: segment.speaker).track == .mic {
            let duration = max(0, segment.end - segment.start)
            guard duration > 0 else { continue }
            totalTime[segment.speaker, default: 0] += duration
            if rms(of: file, from: segment.start, to: segment.end, rate: rate) < silentDBFS {
                silentTime[segment.speaker, default: 0] += duration
            }
        }
        return Set(totalTime.compactMap { speaker, total in
            (silentTime[speaker] ?? 0) / total >= requiredShare ? speaker : nil
        })
    }

    /// Reads only the requested stretch rather than the whole track: a speaker
    /// has tens of turns, and a long meeting's 16 kHz sidecar would otherwise be
    /// pulled into memory during speaker naming.
    private static func rms(
        of file: AVAudioFile, from start: TimeInterval, to end: TimeInterval, rate: Double,
    ) -> Double {
        let first = AVAudioFramePosition(start * rate)
        let count = AVAudioFrameCount(max(0, (end - start) * rate))
        guard first >= 0, first < file.length, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)
        else { return 0 }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: count)) != nil,
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0
        else { return 0 }
        var acc = 0.0
        for i in 0 ..< Int(buffer.frameLength) {
            acc += Double(channel[i]) * Double(channel[i])
        }
        let value = (acc / Double(buffer.frameLength)).squareRoot()
        return value > 0 ? 20 * log10(value) : -.infinity
    }
}
