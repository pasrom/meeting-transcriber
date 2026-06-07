/// A rolling buffer of the most recent 16 kHz mono samples ingested by a
/// streaming ASR session, addressable by absolute millisecond timestamps.
///
/// **Why this exists:** FluidAudio's streaming end-of-utterance ASR manager
/// exposes the recognized *text* of each finalized utterance plus its absolute
/// millisecond time range, but **no per-utterance audio**. Our downstream live
/// speaker matching needs the exact raw samples of each utterance to compute a
/// voice embedding. The streaming session therefore keeps a parallel copy of
/// everything it fed the manager in this buffer and, at each end-of-utterance,
/// slices out the samples for the manager's reported `[fromMs, toMs)` range.
///
/// Timestamps are *absolute* milliseconds since session start, so the buffer
/// tracks a monotonically increasing total-appended sample counter and maps
/// `ms × 16` to absolute sample indices. As new audio arrives, the oldest
/// samples scroll out (bounded memory); extraction clamps any requested range
/// to what is still buffered.
struct UtteranceRingBuffer {
    /// 16 kHz: 1 ms == 16 samples. Fixed by the streaming pipeline (YAGNI —
    /// not parameterized; the whole live path runs at 16 kHz mono).
    private let samplesPerMs = 16

    /// Maximum number of samples retained. Older samples scroll out on append.
    private let capacitySamples: Int

    /// The retained samples, oldest first. Length never exceeds `capacitySamples`.
    private var samples: [Float] = []

    /// Total samples ever appended, across all calls. The absolute index of the
    /// first retained sample is `totalAppended - samples.count`.
    private var totalAppended = 0

    /// - Parameter capacitySamples: how many of the most recent samples to keep.
    ///   Defaults to 480_000 == 30 s at 16 kHz, which bounds memory for the live
    ///   path. A smaller value is mainly useful in tests to exercise wrap-around.
    init(capacitySamples: Int = 480_000) {
        self.capacitySamples = capacitySamples
    }

    /// Appends `newSamples`, advancing the absolute counter, and drops the
    /// oldest samples so at most `capacitySamples` are retained.
    mutating func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        totalAppended += newSamples.count
        samples.append(contentsOf: newSamples)
        let overflow = samples.count - capacitySamples
        if overflow > 0 {
            samples.removeFirst(overflow)
        }
    }

    /// Returns the samples for absolute millisecond range `[fromMs, toMs)`,
    /// mapped to absolute sample indices `[fromMs*16, toMs*16)` and clamped to
    /// what is still buffered (and to what has been appended at all).
    ///
    /// Returns `[]` for empty/inverted ranges, ranges that start at or past the
    /// end of appended audio, or ranges that have fully scrolled out of the buffer.
    func extract(fromMs: Int, toMs: Int) -> [Float] {
        // Desired absolute sample range, with negatives clamped to the start.
        let desiredStart = max(0, fromMs * samplesPerMs)
        let desiredEnd = toMs * samplesPerMs

        // Absolute index of the oldest retained sample.
        let bufferedStart = totalAppended - samples.count
        let bufferedEnd = totalAppended

        // Clamp the desired range to what is actually buffered.
        let start = max(desiredStart, bufferedStart)
        let end = min(desiredEnd, bufferedEnd)
        guard start < end else { return [] }

        // Translate absolute indices into offsets within `samples`.
        let lo = start - bufferedStart
        let hi = end - bufferedStart
        return Array(samples[lo ..< hi])
    }
}
