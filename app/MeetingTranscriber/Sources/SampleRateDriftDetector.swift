import AudioTapLib
import Foundation

/// Watches the actual sample rate delivered by a `LiveAudioSink` vs the
/// rate declared in `LiveAudioBuffer.sampleRate` and reports when they
/// diverge by more than `driftThreshold`. CATap (and CoreAudio more
/// generally) can lie about its rate during USB hot-plug, sample-rate
/// renegotiations, or HFP↔A2DP transitions — the buffer header keeps
/// claiming 48 kHz while the IOProc is actually delivering slightly more
/// or slightly fewer samples per wall-clock second. Without detection,
/// `LiveAudioResampler` builds a converter against the stale claimed rate
/// and the transcribed text comes out time-warped (typically a few %).
///
/// Computed across a sliding window of the last `windowSeconds` of
/// buffers using `mach_absolute_time()` ticks, since that's what
/// `LiveAudioBuffer.hostTime` carries. Pure value type (no actor
/// isolation) so it can be observed from any context and unit-tested with
/// synthetic buffers.
struct SampleRateDriftDetector {
    /// Trailing window for the observed-rate average. Long enough to
    /// smooth out per-buffer jitter (CATap typically delivers in 5–10 ms
    /// chunks), short enough to react to real drift in a few seconds.
    static let windowSeconds: Double = 5.0
    /// Throttle for repeat warnings on the same drift episode — without
    /// this, a continuous-drift session would flood the log at every
    /// buffer (≈100/s at 48 kHz × 480-frame chunks).
    static let warnCooldownSeconds: Double = 30.0
    /// Fraction of the claimed rate above which we warn. 5 % is well
    /// past CoreAudio's normal sample-rate clock-drift (±50 ppm = 0.005 %)
    /// so a hit here is a real configuration-vs-reality mismatch.
    static let driftThreshold: Double = 0.05

    private struct Entry {
        let hostTime: UInt64
        let frames: Int
        let claimedRate: Int
    }

    private var entries: [Entry] = []
    private var lastWarningAt: Date = .distantPast

    struct Report: Equatable {
        let claimedRate: Double
        let observedRate: Double
        let driftFraction: Double
    }

    /// Record a buffer. Returns a `Report` exactly when (a) drift exceeds
    /// `driftThreshold` AND (b) the cooldown since the last warning has
    /// elapsed — caller logs. Returns nil otherwise.
    mutating func observe(_ buffer: LiveAudioBuffer, now: Date = Date()) -> Report? {
        let frames = buffer.samples.count / max(buffer.channelCount, 1)
        guard frames > 0 else { return nil }
        entries.append(Entry(
            hostTime: buffer.hostTime,
            frames: frames,
            claimedRate: buffer.sampleRate,
        ))
        prune()
        return checkDrift(now: now)
    }

    private mutating func prune() {
        guard let newestTime = entries.last?.hostTime else { return }
        let windowTicks = Self.secondsToMachTicks(Self.windowSeconds)
        let cutoff = newestTime > windowTicks ? newestTime - windowTicks : 0
        entries.removeAll { $0.hostTime < cutoff }
    }

    private mutating func checkDrift(now: Date) -> Report? {
        guard entries.count >= 4,
              let first = entries.first,
              let last = entries.last else { return nil }
        let elapsedSeconds = Self.machTicksToSeconds(last.hostTime &- first.hostTime)
        guard elapsedSeconds >= 1.0 else { return nil }
        // Skip the first entry: its samples were captured BEFORE
        // first.hostTime (they're what got buffered for delivery AT that
        // moment). Counting them inflates the observed rate because the
        // numerator grows by N but the denominator only by N-1 intervals.
        let totalFrames = entries.dropFirst().reduce(0) { $0 + $1.frames }
        let observedRate = Double(totalFrames) / elapsedSeconds
        let claimedRate = Double(last.claimedRate)
        guard claimedRate > 0 else { return nil }
        let drift = abs(observedRate - claimedRate) / claimedRate
        guard drift > Self.driftThreshold else { return nil }
        guard now.timeIntervalSince(lastWarningAt) > Self.warnCooldownSeconds else { return nil }
        lastWarningAt = now
        return Report(
            claimedRate: claimedRate,
            observedRate: observedRate,
            driftFraction: drift,
        )
    }

    // mach_absolute_time helpers re-implemented here (AudioTapLib's
    // versions are package-internal). Cached at first use.
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func machTicksToSeconds(_ ticks: UInt64) -> Double {
        let nanos = Double(ticks) * Double(machTimebase.numer) / Double(machTimebase.denom)
        return nanos / 1_000_000_000.0
    }

    static func secondsToMachTicks(_ seconds: Double) -> UInt64 {
        let nanos = seconds * 1_000_000_000
        return UInt64(nanos * Double(machTimebase.denom) / Double(machTimebase.numer))
    }
}
