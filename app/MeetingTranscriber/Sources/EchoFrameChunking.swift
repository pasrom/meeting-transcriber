// Pure hop arithmetic for streaming a signal through a fixed-hop frame API
// (LocalVQE processes 256-sample hops): how many hops a signal needs, where
// each starts, how much of the trailing partial hop is real signal, and the
// zero-padded window copy both tracks use. Extracted as a value type so the
// chunking logic is testable without the C library or a model.

/// Slices `totalSamples` into consecutive `hopLength`-sized windows. The last
/// window may be partial: it is fed to the frame API zero-padded, and only its
/// `validSamples` of output are kept.
struct EchoFrameChunking {
    struct Hop: Equatable {
        /// Sample offset of this hop's window in the source signal.
        let start: Int
        /// Samples of real signal in this window — equal to the hop length
        /// except for a trailing partial hop.
        let validSamples: Int
    }

    let totalSamples: Int
    let hopLength: Int

    /// Number of hops needed to cover the whole signal (ceiling division).
    var hopCount: Int {
        guard totalSamples > 0, hopLength > 0 else { return 0 }
        return (totalSamples + hopLength - 1) / hopLength
    }

    /// The window at `index` (0 ..< `hopCount`).
    func hop(_ index: Int) -> Hop {
        let start = index * hopLength
        return Hop(start: start, validSamples: min(hopLength, totalSamples - start))
    }

    /// Copies `buffer.count` samples of `signal` starting at `start` into
    /// `buffer`, zero-filling everything past the signal's end. Used for the
    /// trailing partial hop and for a reference track shorter than the mic
    /// track, where reading past the end must produce silence.
    ///
    /// Deliberately static and taking a bare `start`: the reference track is
    /// read at the MIC chunking's offsets, so the signal and the chunking that
    /// produced the offset are routinely different lengths. Taking a `Hop` would
    /// suggest an invariant this call does not have.
    ///
    /// Copies in bulk rather than element by element: the scalar loop paid a
    /// bounds check per sample on every hop, including the full ones that need
    /// no padding at all.
    static func fillHop(from signal: [Float], start: Int, into buffer: inout [Float]) {
        let available = max(0, min(buffer.count, signal.count - start))
        if available > 0 {
            buffer.replaceSubrange(0 ..< available, with: signal[start ..< start + available])
        }
        if available < buffer.count {
            buffer.replaceSubrange(available ..< buffer.count, with: repeatElement(0, count: buffer.count - available))
        }
    }
}
