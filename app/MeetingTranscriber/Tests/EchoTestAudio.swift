import Foundation

/// Synthetic audio for the echo-bleed tests, shared so the detector's unit
/// tests and the pipeline-level tests measure the same signal. They did not
/// always: a second, sine-enveloped copy grew in the pipeline tests and made
/// its negative case far easier than reality, which is the failure this
/// consolidation removes.
enum EchoTestAudio {
    static let rate = 16000

    /// Speech-like: noise shaped by a slow **aperiodic** envelope.
    ///
    /// Two properties matter and both were learned the hard way. The envelope
    /// has to vary with the seed, not just the carrier, or two supposedly
    /// independent talkers correlate at exactly 1.0 — the detector compares
    /// envelopes, so an identical envelope is an identical signal to it. And it
    /// must not be periodic: a sine envelope correlates with itself at every
    /// multiple of its period, so a copy delayed far outside the search window
    /// is still "found", which made a lag-boundary test pass for the wrong
    /// reason. A periodic envelope also makes two talkers at different
    /// syllable rates nearly orthogonal, so a negative test built on one
    /// certifies a margin real recordings do not have: clean pairs in the
    /// corpus reach 0.3 to 0.55 per window, not 0.
    static func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed &+ 1
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(UInt32(truncatingIfNeeded: state >> 33)) / Double(UInt32.max)
        }
        // One envelope control point per 120 ms, linearly interpolated: syllable
        // rhythm without a period to lock onto.
        let step = Int(0.12 * Double(rate))
        let points = (0 ... (Int(Double(rate) * seconds) / step + 2)).map { _ in
            let v = next()
            return v < 0.35 ? 0.0 : v // pauses
        }
        return (0 ..< Int(Double(rate) * seconds)).map { i in
            let carrier = Float(next() * 2 - 1)
            let idx = i / step
            let frac = Double(i % step) / Double(step)
            let env = points[idx] * (1 - frac) + points[idx + 1] * frac
            return carrier * Float(env)
        }
    }

    /// The room path: the loudspeaker output reaching the microphone,
    /// attenuated and delayed.
    static func bleed(_ source: [Float], delayMs: Double, gain: Float) -> [Float] {
        let d = Int(delayMs / 1000 * Double(rate))
        var out = [Float](repeating: 0, count: source.count)
        for i in d ..< source.count {
            out[i] = source[i - d] * gain
        }
        return out
    }
}
