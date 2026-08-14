import Foundation

/// Decides whether a dual-source recording has the loudspeaker output coming
/// back through the microphone, so both tracks carry the same speech.
///
/// Why it matters: transcription runs on the two tracks separately and
/// `DiarizationProcess.mergeDualSourceSegments` interleaves them without any
/// dedup, so every affected utterance is transcribed twice and lands in the
/// transcript twice. The mic-track diarization also sees the bled-in voice,
/// which pollutes the speaker list and can fold a foreign voice into a stored
/// centroid. The remedy is the user's, not ours: headphones.
///
/// **The metric is the share of windows, not a correlation over the file.** A
/// whole-file correlation dilutes partial bleed: a reproduced echo recording
/// measured 0.92 inside its echo phases and 0.657 across the file, so a global
/// threshold would miss the very case that motivates this. Nor is the window
/// *maximum* usable: clean recordings reach 0.3 to 0.55.
///
/// Thresholds come from 86 dual-source pairs. Among recordings of meeting
/// length the affected ones carried 34 %, 60 % and 77 % of their windows above
/// a per-window correlation of 0.7, one borderline case sat at 4 %, and twenty
/// clean recordings sat at exactly 0 %. `affectedShareThreshold` is placed in
/// that gap.
enum EchoBleedDetector {
    /// Envelope resolution. Correlating envelopes rather than waveforms is what
    /// makes this robust to the two capture chains having different gain and
    /// frequency response, which they always do.
    static let frameSeconds = 0.010
    static let windowSeconds = 10.0
    /// The measured inter-track offset is 10 to 20 ms. A wider search adds no
    /// reach and inflates every value, since taking a maximum over more
    /// candidates is a multiple-comparisons bias.
    static let maxLagSeconds = 0.2
    static let correlationThreshold = 0.7
    static let affectedShareThreshold = 0.15
    /// A share is only evidence once there is something to take a share of.
    /// With one scored window the share is quantised to 0 % or 100 %, so a
    /// single coincidentally hot window in a short clip would produce a
    /// confident verdict; the corpus shows even clean recordings throw isolated
    /// hot windows. Both floors must be cleared, not either.
    static let minScoredWindows = 3
    static let minAffectedWindows = 2
    /// Below this a track carries no signal, and a dead channel cannot bleed
    /// anywhere. That is a different defect, handled by the channel-health path.
    static let silenceFloorDBFS = -70.0

    struct Result: Equatable {
        /// Share of 10 s windows whose two tracks carry the same audio.
        let affectedWindowShare: Double
        let windowsScored: Int
        let windowsAffected: Int

        var isAffected: Bool {
            windowsScored >= EchoBleedDetector.minScoredWindows
                && windowsAffected >= EchoBleedDetector.minAffectedWindows
                && affectedWindowShare > EchoBleedDetector.affectedShareThreshold
        }
    }

    /// Returns `nil` when no honest verdict is possible: either track silent, or
    /// less than one full window of overlap. A share computed over half a window
    /// is not a measurement, and reporting one would put a claim about the user's
    /// audio behind a number that cannot support it.
    /// `micDelay` is the recorder's own estimate of how far the mic track lags
    /// the app track, the same value the merge and the mic diarization are
    /// shifted by. The lag search is centred on it rather than on zero: the two
    /// files' sample 0 are not simultaneous, and a mic that starts more than the
    /// search window late (a Bluetooth device spinning up manages this) would
    /// put real bleed outside the window and read as clean. A false negative
    /// there is invisible, which is the worst kind.
    static func analyse(
        app: [Float],
        mic: [Float],
        sampleRate: Int,
        micDelay: TimeInterval = 0,
    ) -> Result? {
        let overlap = min(app.count, mic.count)
        let framesPerWindow = Int(windowSeconds / frameSeconds)
        let samplesPerFrame = Int(Double(sampleRate) * frameSeconds)
        guard samplesPerFrame > 0, overlap >= samplesPerFrame * framesPerWindow else { return nil }

        guard dbfs(app, count: overlap) > silenceFloorDBFS,
              dbfs(mic, count: overlap) > silenceFloorDBFS
        else { return nil }

        let appEnvelope = envelope(app, count: overlap, samplesPerFrame: samplesPerFrame)
        let micEnvelope = envelope(mic, count: overlap, samplesPerFrame: samplesPerFrame)

        let windows = min(appEnvelope.count, micEnvelope.count) / framesPerWindow
        guard windows > 0 else { return nil }

        let maxLag = Int(maxLagSeconds / frameSeconds)
        let centreLag = Int((micDelay / frameSeconds).rounded())
        var affected = 0
        var scored = 0
        for w in 0 ..< windows {
            let range = (w * framesPerWindow) ..< ((w + 1) * framesPerWindow)
            guard let r = peakCorrelation(
                Array(appEnvelope[range]),
                Array(micEnvelope[range]),
                maxLag: maxLag,
                centre: centreLag,
            )
            else { continue }
            scored += 1
            if r > correlationThreshold { affected += 1 }
        }
        guard scored > 0 else { return nil }
        return Result(
            affectedWindowShare: Double(affected) / Double(scored),
            windowsScored: scored,
            windowsAffected: affected,
        )
    }

    // MARK: - Pieces

    private static func dbfs(_ samples: [Float], count: Int) -> Double {
        guard count > 0 else { return -.infinity }
        var acc = 0.0
        for i in 0 ..< count {
            acc += Double(samples[i]) * Double(samples[i])
        }
        let rms = (acc / Double(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    private static func envelope(_ samples: [Float], count: Int, samplesPerFrame: Int) -> [Double] {
        let frames = count / samplesPerFrame
        var out = [Double](repeating: 0, count: frames)
        for f in 0 ..< frames {
            var acc = 0.0
            for i in (f * samplesPerFrame) ..< ((f + 1) * samplesPerFrame) {
                acc += Double(samples[i]) * Double(samples[i])
            }
            out[f] = (acc / Double(samplesPerFrame)).squareRoot()
        }
        return out
    }

    /// Highest normalised correlation of `b` against `a` over the lag range.
    /// `nil` when either side is flat in this window, which carries no evidence
    /// either way.
    private static func peakCorrelation(
        _ a: [Double],
        _ b: [Double],
        maxLag: Int,
        centre: Int,
    ) -> Double? {
        var best: Double?
        for offset in -maxLag ... maxLag {
            let lag = centre + offset
            let x: ArraySlice<Double>
            let y: ArraySlice<Double>
            if lag >= 0 {
                guard lag < a.count else { continue }
                x = a[0 ..< (a.count - lag)]
                y = b[lag ..< b.count]
            } else {
                guard -lag < a.count else { continue }
                x = a[(-lag) ..< a.count]
                y = b[0 ..< (b.count + lag)]
            }
            guard let r = correlation(x, y) else { continue }
            best = max(best ?? r, r)
        }
        return best
    }

    private static func correlation(_ x: ArraySlice<Double>, _ y: ArraySlice<Double>) -> Double? {
        let n = min(x.count, y.count)
        guard n > 1 else { return nil }
        let xs = Array(x.prefix(n))
        let ys = Array(y.prefix(n))
        let mx = xs.reduce(0, +) / Double(n)
        let my = ys.reduce(0, +) / Double(n)
        var num = 0.0
        var dx = 0.0
        var dy = 0.0
        for i in 0 ..< n {
            let a = xs[i] - mx
            let b = ys[i] - my
            num += a * b
            dx += a * a
            dy += b * b
        }
        guard dx > 0, dy > 0 else { return nil }
        return num / (dx * dy).squareRoot()
    }
}
