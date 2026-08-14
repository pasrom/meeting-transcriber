@testable import MeetingTranscriber
import Foundation

/// Builds a double-talk fixture for the echo-cancellation quality tests: a
/// local speaker talking continuously while the remote side bleeds in from the
/// loudspeaker.
///
/// **Deliberately not `scripts/fixtures/make-echo-pair.py`, and the difference
/// is the whole point.** That generator gates the local speaker into 1.5 s
/// bursts so the *detector* fires; it cuts local speech mid-word, so no ground
/// truth is derivable from the source fixture's `_truth.json`. Here the local
/// track is left continuous, which keeps its committed truth valid word for
/// word — and continuous local speech over an active reference is exactly the
/// double-talk regime, the classic way an echo canceller damages the person at
/// the machine. Do not "unify" the two.
///
/// Everything is derived at test time from committed fixtures, so no synthesised
/// audio enters the repository.
enum EchoQualityMix {
    static let rate = AudioConstants.targetSampleRate

    /// The local speaker's own recording, plus the remote side arriving through
    /// the room. `bleedGain` 1.0 mirrors what an affected recording looks like:
    /// a microphone centimetres from the loudspeaker hears the far end about as
    /// loudly as the person sitting there.
    static func doubleTalk(
        local: [Float], remote: [Float], bleedGain: Float = 1.0, delayMs: Double = 15,
    ) -> (mic: [Float], reference: [Float]) {
        let reference = tiled(remote, to: local.count)
        let echo = EchoTestAudio.bleed(reference, delayMs: delayMs, gain: bleedGain)
        var mic = local
        for i in 0 ..< min(mic.count, echo.count) {
            mic[i] = clamp(mic[i] + echo[i])
        }
        return (mic, reference)
    }

    /// Repeats `source` to `count` samples, crossfading each seam.
    ///
    /// The crossfade is not cosmetic: a hard splice is a step discontinuity, and
    /// an adaptive filter re-converges after one, which would show up as
    /// residual echo that belongs to the fixture rather than to the canceller.
    static func tiled(_ source: [Float], to count: Int, crossfade: Int = 320) -> [Float] {
        guard !source.isEmpty else { return [Float](repeating: 0, count: count) }
        guard source.count > crossfade * 2 else {
            return (0 ..< count).map { source[$0 % source.count] }
        }
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count {
            if out.isEmpty {
                out.append(contentsOf: source)
                continue
            }
            // Overlap the tail of what we have with the head of the next copy.
            let start = out.count - crossfade
            for k in 0 ..< crossfade {
                let t = Float(k) / Float(crossfade)
                out[start + k] = out[start + k] * (1 - t) + source[k] * t
            }
            out.append(contentsOf: source[crossfade...])
        }
        return Array(out[0 ..< count])
    }

    private static func clamp(_ v: Float) -> Float {
        min(max(v, -1), 1)
    }
}
