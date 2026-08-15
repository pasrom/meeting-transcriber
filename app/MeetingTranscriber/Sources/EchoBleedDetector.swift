import Foundation

/// What the echo detector concluded about one recording.
///
/// Three cases and not a `Bool`, because the third one is load-bearing
/// everywhere this travels: *not measured* is not *measured and clean*. A
/// single-source job is never analysed, and a dual-source pair can be silent or
/// too short for one full window, in which case no honest verdict exists. Code
/// that collapses those into `false` reports a recording as fine that nobody
/// ever looked at — and on the speaker-database side, decides it is safe to
/// learn from audio it never checked.
///
/// Not persisted, and deliberately so: `PipelineJob.echo` is the one stored
/// copy, and this is derived from it wherever a decision needs the three-way
/// distinction. A second stored copy could go stale against the first, and the
/// way it would fail is silent — a recording that was affected reading as
/// unmeasured, which lifts the quarantine on the audio that most needs it.
enum EchoVerdict: Equatable {
    case notMeasured
    case clean
    case affected

    init(_ detection: EchoDetectionDTO?) {
        guard let detection else {
            self = .notMeasured
            return
        }
        self = detection.detected ? .affected : .clean
    }
}

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

    /// One window's measurement, kept so a field report is diagnosable without
    /// the audio. The lag is what separates real bleed from a coincidence: bleed
    /// peaks at a stable lag near the recorder's own track offset, whereas two
    /// tracks that merely happen to rise and fall together peak wherever.
    struct WindowScore: Equatable {
        let correlation: Double
        let lagSeconds: Double
    }

    struct Result: Equatable {
        /// Per-window measurements, in order, and the only stored state.
        /// Never empty: a `Result` is only produced once a window scored.
        let windowScores: [WindowScore]

        var windowsScored: Int {
            windowScores.count
        }

        /// Derived rather than counted alongside the series, so the summary and
        /// the evidence it summarises cannot disagree — and so the threshold
        /// lives next to the field it defines instead of in the scoring loop.
        var windowsAffected: Int {
            windowScores.count { $0.correlation > EchoBleedDetector.correlationThreshold }
        }

        /// Share of 10 s windows whose two tracks carry the same audio.
        var affectedWindowShare: Double {
            windowsScored > 0 ? Double(windowsAffected) / Double(windowsScored) : 0
        }

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

        // Both envelopes are built from the same `overlap` and frame size, so
        // they are the same length; and the guard above already forced at least
        // one whole window.
        let windows = appEnvelope.count / framesPerWindow

        let maxLag = Int(maxLagSeconds / frameSeconds)
        // Negative, and the sign is the whole point. `micDelay > 0` means the
        // mic started LATE, so its file is missing that opening stretch and its
        // copy of the app audio sits *earlier* in file-index terms — the same
        // convention `AudioMixer.mix` encodes by prepending zeros to a late mic
        // and `mergeDualSourceSegments` by shifting mic times `+micDelay`.
        // `peakCorrelation` pairs `app[k]` with `mic[k + lag]`, so the match is
        // at `lag = -micDelay`. Getting this backwards is worse than passing no
        // delay at all: it searches twice the offset away from the peak.
        let centreLag = -Int((micDelay / frameSeconds).rounded())
        let scores = (0 ..< windows).compactMap { w -> WindowScore? in
            let range = (w * framesPerWindow) ..< ((w + 1) * framesPerWindow)
            guard let peak = peakCorrelation(
                appEnvelope[range],
                micEnvelope[range],
                maxLag: maxLag,
                centre: centreLag,
            )
            else { return nil }
            return WindowScore(
                correlation: peak.correlation,
                lagSeconds: Double(peak.lag) * frameSeconds,
            )
        }
        guard !scores.isEmpty else { return nil }
        return Result(windowScores: scores)
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

    /// Highest normalised correlation of `b` against `a` over the lag range, and
    /// the lag it peaked at. `nil` when either side is flat in this window,
    /// which carries no evidence either way.
    private static func peakCorrelation(
        _ a: ArraySlice<Double>,
        _ b: ArraySlice<Double>,
        maxLag: Int,
        centre: Int,
    ) -> (correlation: Double, lag: Int)? {
        var best: (correlation: Double, lag: Int)?
        for offset in -maxLag ... maxLag {
            let lag = centre + offset
            // Shifting `b` right by `lag` and clipping both to the part that
            // still overlaps. Written once rather than as a mirrored pair of
            // branches: a negative lag is the same slice arithmetic with the
            // two offsets swapped.
            let overlap = a.count - abs(lag)
            guard overlap > 1 else { continue }
            let aStart = a.startIndex + max(0, -lag)
            let bStart = b.startIndex + max(0, lag)
            let x = a[aStart ..< (aStart + overlap)]
            let y = b[bStart ..< (bStart + overlap)]
            guard let r = correlation(x, y) else { continue }
            // Floor at -infinity rather than 0: a correlation is signed, and the
            // first candidate has to win however negative it is.
            if r > (best?.correlation ?? -.infinity) {
                best = (correlation: r, lag: lag)
            }
        }
        return best
    }

    /// The two slices are equal-length by construction in `peakCorrelation`.
    /// Iterated pairwise over the slices rather than copied into arrays first:
    /// this runs once per candidate lag per window, so the copies added up
    /// without buying anything.
    private static func correlation(_ x: ArraySlice<Double>, _ y: ArraySlice<Double>) -> Double? {
        let n = x.count
        guard n > 1 else { return nil }
        let mx = x.reduce(0, +) / Double(n)
        let my = y.reduce(0, +) / Double(n)
        var num = 0.0
        var dx = 0.0
        var dy = 0.0
        for (xi, yi) in zip(x, y) {
            let a = xi - mx
            let b = yi - my
            num += a * b
            dx += a * a
            dy += b * b
        }
        guard dx > 0, dy > 0 else { return nil }
        return num / (dx * dy).squareRoot()
    }
}
