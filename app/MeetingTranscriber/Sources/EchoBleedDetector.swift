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
    /// The lag search around the recorder's own alignment, in seconds, and
    /// asymmetric on purpose. Positive means the microphone copy arrives later.
    ///
    /// Bleed arrives late by the room path plus whatever the output device
    /// adds: built-in speakers keep that small, but an external or Bluetooth
    /// output puts the copy well past 200 ms, where a symmetric search found
    /// nothing and the recording read as clean. Hence the longer upper edge.
    /// The lower edge stays at 200 ms because the recorder's alignment itself
    /// can overshoot, and narrowing it lost real detections in a replay over
    /// the recorded calls the thresholds were calibrated on.
    ///
    /// Not wider than this, because taking a maximum over more candidates is a
    /// multiple-comparisons bias that inflates every value; the same replay
    /// found the extra 100 ms added almost no hot windows on clean calls.
    static let earliestLagSeconds = -0.2
    static let latestLagSeconds = 0.3
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

    /// When the far end is talking, judged from the app track alone. A frame
    /// is active when its level is within `farEndActiveRangeDB` of the track's
    /// own speech level (its `farEndLevelPercentile` frame level over the
    /// analysed span) and above `farEndActiveFloorDBFS`; a window is far-end
    /// active when at least `farEndActiveFrameShare` of its frames are. Relative
    /// to the track rather than absolute, because call levels differ by tens of
    /// dB between apps and devices, while an idle line sits far below whatever
    /// level that call's speech has.
    static let farEndLevelPercentile = 0.95
    static let farEndActiveRangeDB = 25.0
    static let farEndActiveFloorDBFS = -60.0
    static let farEndActiveFrameShare = 0.05

    /// Bleed travels one fixed path, so its windows peak at one lag even where
    /// a louder local talker keeps them under `correlationThreshold`. The lock
    /// is the share of scored windows peaking within `lagLockToleranceSeconds`
    /// of the lag most hot windows peaked at. That lag has to sit at least
    /// `lagLockEdgeMarginSeconds` inside both search edges: a clean call piles
    /// its peaks up at an edge, wherever the correlation is still rising when
    /// the search stops, and a pile-up there is not a path.
    static let lagLockToleranceSeconds = 0.01
    static let lockedShareThreshold = 0.3
    static let lagLockEdgeMarginSeconds = 0.03

    /// Which rule called a recording affected, for the log line that makes a
    /// field report diagnosable.
    enum Route: String {
        /// Hot windows over every scored window: the original rule.
        case share
        /// Hot windows over the windows the far end talked in.
        case farEndShare
        /// Scored windows locked to one bleed path.
        case lockedLag
    }

    /// One window's measurement, kept so a field report is diagnosable without
    /// the audio. The lag is what separates real bleed from a coincidence: bleed
    /// peaks at a stable lag near the recorder's own track offset, whereas two
    /// tracks that merely happen to rise and fall together peak wherever.
    struct WindowScore: Equatable {
        let correlation: Double
        let lagSeconds: Double
        /// Share of this window's frames in which the far end was talking.
        let farEndActivity: Double

        init(correlation: Double, lagSeconds: Double, farEndActivity: Double) {
            self.correlation = correlation
            self.lagSeconds = lagSeconds
            self.farEndActivity = farEndActivity
        }

        var isHot: Bool {
            correlation > EchoBleedDetector.correlationThreshold
        }

        var farEndActive: Bool {
            farEndActivity >= EchoBleedDetector.farEndActiveFrameShare
        }
    }

    struct Result: Equatable {
        /// Every analysed window in order, `nil` where an envelope was flat and
        /// the window could not be scored. Kept with its gaps so the n-th entry
        /// is the n-th ten seconds of the recording.
        let windows: [WindowScore?]
        /// The microphone delay the search was centred on, so a lag can be
        /// read relative to the centre.
        let micDelay: TimeInterval

        /// The scored windows only, in order, which is what every rule counts.
        /// Never empty: a `Result` is only produced once a window scored.
        var windowScores: [WindowScore] {
            windows.compactMap(\.self)
        }

        var windowsScored: Int {
            windowScores.count
        }

        /// Derived rather than counted alongside the series, so the summary and
        /// the evidence it summarises cannot disagree — and so the threshold
        /// lives next to the field it defines instead of in the scoring loop.
        var windowsAffected: Int {
            windowScores.count(where: \.isHot)
        }

        /// Share of 10 s windows whose two tracks carry the same audio.
        var affectedWindowShare: Double {
            windowsScored > 0 ? Double(windowsAffected) / Double(windowsScored) : 0
        }

        /// The lag most hot windows peaked at, in frames from the search
        /// centre, and how many scored windows peaked within the tolerance of
        /// it. `nil` when no window is hot, since the mode is taken over the
        /// hot windows only: a cold window's peak lag is wherever a coincidence
        /// put it. Ties go to the lag that locks the most windows, then to the
        /// one the earliest hot window peaked at (`max(by:)` keeps the first of
        /// equal elements).
        private func lagLock(_ scores: [WindowScore]) -> (offset: Int, locked: Int)? {
            let centre = EchoBleedDetector.frames(-micDelay)
            let offsets = scores.map { EchoBleedDetector.frames($0.lagSeconds) - centre }
            var counts: [Int: Int] = [:]
            var firstSeen: [Int] = []
            for (score, offset) in zip(scores, offsets) where score.isHot {
                if counts[offset] == nil { firstSeen.append(offset) }
                counts[offset, default: 0] += 1
            }
            guard let top = counts.values.max() else { return nil }
            let tolerance = EchoBleedDetector.frames(EchoBleedDetector.lagLockToleranceSeconds)
            return firstSeen
                .filter { counts[$0] == top }
                .map { mode in (offset: mode, locked: offsets.count { abs($0 - mode) <= tolerance }) }
                .max { $0.locked < $1.locked }
        }

        /// Every rule that calls this recording affected, in the order above.
        /// The share over every scored window is the original rule. The share
        /// over the far-end windows catches a call where the far end talks in
        /// few windows and bleeds in all of them, which the first rule dilutes
        /// with windows nothing came out of the loudspeaker in. The lag lock
        /// catches bleed masked by a louder local talker, which keeps all but a
        /// few windows under the per-window threshold but not off the path.
        var routes: [Route] {
            let scores = windowScores
            let hot = scores.count(where: \.isHot)
            var fired: [Route] = []
            if EchoBleedDetector.sharePasses(scored: scores.count, hot: hot) {
                fired.append(.share)
            }
            let farEnd = scores.filter(\.farEndActive)
            if EchoBleedDetector.sharePasses(scored: farEnd.count, hot: farEnd.count(where: \.isHot)) {
                fired.append(.farEndShare)
            }
            if lagLockPasses(scores, hot: hot) {
                fired.append(.lockedLag)
            }
            return fired
        }

        var isAffected: Bool {
            !routes.isEmpty
        }

        /// The same two floors as the share rules, then a lock on a lag that
        /// is not an edge of the search.
        private func lagLockPasses(_ scores: [WindowScore], hot: Int) -> Bool {
            guard EchoBleedDetector.floorsPass(scored: scores.count, hot: hot),
                  let lock = lagLock(scores),
                  Double(lock.locked) / Double(scores.count) > EchoBleedDetector.lockedShareThreshold
            else { return false }
            let margin = EchoBleedDetector.frames(EchoBleedDetector.lagLockEdgeMarginSeconds)
            return EchoBleedDetector.frames(EchoBleedDetector.earliestLagSeconds) + margin <= lock.offset
                && lock.offset <= EchoBleedDetector.frames(EchoBleedDetector.latestLagSeconds) - margin
        }
    }

    /// Seconds as a whole number of envelope frames, rounded the way the
    /// search centre is.
    private static func frames(_ seconds: Double) -> Int {
        Int((seconds / frameSeconds).rounded())
    }

    /// The two floors every route has to clear, in one place so they cannot
    /// drift apart between routes.
    private static func floorsPass(scored: Int, hot: Int) -> Bool {
        scored >= minScoredWindows && hot >= minAffectedWindows
    }

    private static func sharePasses(scored: Int, hot: Int) -> Bool {
        floorsPass(scored: scored, hot: hot) && Double(hot) / Double(scored) > affectedShareThreshold
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

        let offsets = frames(earliestLagSeconds) ... frames(latestLagSeconds)
        // Negative, and the sign is the whole point. `micDelay > 0` means the
        // mic started LATE, so its file is missing that opening stretch and its
        // copy of the app audio sits *earlier* in file-index terms — the same
        // convention `AudioMixer.mix` encodes by prepending zeros to a late mic
        // and `mergeDualSourceSegments` by shifting mic times `+micDelay`.
        // `peakCorrelation` pairs `app[k]` with `mic[k + lag]`, so the match is
        // at `lag = -micDelay`. Getting this backwards is worse than passing no
        // delay at all: it searches twice the offset away from the peak.
        let centreLag = frames(-micDelay)
        let activity = farEndActivity(appEnvelope[0 ..< (windows * framesPerWindow)], framesPerWindow: framesPerWindow)
        let scores = (0 ..< windows).map { w -> WindowScore? in
            let range = (w * framesPerWindow) ..< ((w + 1) * framesPerWindow)
            guard let peak = peakCorrelation(
                appEnvelope[range],
                micEnvelope[range],
                offsets: offsets,
                centre: centreLag,
            )
            else { return nil }
            return WindowScore(
                correlation: peak.correlation,
                lagSeconds: Double(peak.lag) * frameSeconds,
                farEndActivity: activity[w],
            )
        }
        guard scores.contains(where: { $0 != nil }) else { return nil }
        return Result(windows: scores, micDelay: micDelay)
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

    /// Per window, the share of frames in which the far end was talking (see
    /// `farEndLevelPercentile`). The percentile is taken over the whole span
    /// passed in, which is every frame that belongs to a window: a non-empty
    /// whole number of windows, so neither helper needs an empty or ragged case.
    private static func farEndActivity(_ envelope: ArraySlice<Double>, framesPerWindow: Int) -> [Double] {
        // A digital-zero frame gets a finite, very low level rather than -inf,
        // so it sorts below everything and is never active.
        let levels = envelope.map { 20 * log10(max($0, 1e-10)) }
        let threshold = max(
            percentile(levels.sorted(), farEndLevelPercentile) - farEndActiveRangeDB,
            farEndActiveFloorDBFS,
        )
        return stride(from: 0, to: levels.count, by: framesPerWindow).map { start in
            let window = levels[start ..< (start + framesPerWindow)]
            return Double(window.count { $0 > threshold }) / Double(window.count)
        }
    }

    /// Linear interpolation between the closest ranks, so `p` of 0.95 over a
    /// short span does not jump from one frame's level to the next.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Highest normalised correlation of `b` against `a` over the lag range, and
    /// the lag it peaked at. `nil` when either side is flat in this window,
    /// which carries no evidence either way. `offsets` is in frames around
    /// `centre`; a candidate that leaves too little overlap is skipped, which
    /// keeps a large `micDelay` from reading out of bounds. A delay longer than
    /// a window skips every candidate, so no window scores and there is no
    /// verdict.
    private static func peakCorrelation(
        _ a: ArraySlice<Double>,
        _ b: ArraySlice<Double>,
        offsets: ClosedRange<Int>,
        centre: Int,
    ) -> (correlation: Double, lag: Int)? {
        var best: (correlation: Double, lag: Int)?
        for offset in offsets {
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
