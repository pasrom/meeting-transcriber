import Foundation
@testable import MeetingTranscriber

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

    /// A steady noise floor at `amplitude` (uniform, so RMS is about 0.58 of
    /// it). Stands in for a quiet room or an idle line: low, but never the
    /// digital zero that makes a window unscorable.
    static func noise(seconds: Double, amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return (0 ..< Int(Double(rate) * seconds)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(UInt32(truncatingIfNeeded: state >> 33)) / Float(UInt32.max)
            return (unit * 2 - 1) * amplitude
        }
    }

    /// Sample-wise sum of two tracks, over the shorter length.
    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 + $1 }
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

    /// Noise bursts that alternate with near silence every 0.2 s, so an echo
    /// gate both opens and closes; interleaved when `channels` > 1, at any
    /// rate. Kept next to `speechLike` rather than replaced by it: the
    /// `buildRecording` output pins hash files built from exactly these
    /// samples, and a stereo app temp needs the interleaving.
    static func gatedBursts(seconds: Int, rate: Int, channels: Int, seed: UInt64) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let frames = seconds * rate
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0 ..< frames {
            let loud = (frame / (rate / 5)).isMultiple(of: 2)
            for channel in 0 ..< channels {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float(state >> 40) / Float(1 << 24) * 2 - 1
                samples[frame * channels + channel] = unit * (loud ? 0.5 : 0.001)
            }
        }
        return samples
    }
}

/// Hand-built detector results for tests that need a verdict, not a
/// measurement. They live in the test target so production code always states
/// the far-end activity and the delay it measured; here every window counts as
/// far-end active, which makes the far-end share equal the plain share.
extension EchoBleedDetector.WindowScore {
    init(correlation: Double, lagSeconds: Double) {
        self.init(correlation: correlation, lagSeconds: lagSeconds, farEndActivity: 1)
    }
}

extension EchoBleedDetector.Result {
    init(windowScores: [EchoBleedDetector.WindowScore], micDelay: TimeInterval = 0) {
        self.init(windows: windowScores, micDelay: micDelay)
    }
}
