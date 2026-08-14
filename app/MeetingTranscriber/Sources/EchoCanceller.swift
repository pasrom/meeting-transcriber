import CLocalVQE
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "EchoCanceller")

/// Removes the far-end echo from a microphone track, given the app track as the
/// reference of what the loudspeaker played.
///
/// Wraps LocalVQE (Apache-2.0), a streaming CPU derivative of DeepVQE: a
/// classical adaptive filter followed by a small neural mask. The v1.4-AEC
/// build is echo-only — it passes voice, room and background through unchanged,
/// which is what makes it safe here. A joint denoise/dereverb model would move
/// the spectrum the speaker embeddings depend on, and this pipeline compares
/// those embeddings against a persistent database.
///
/// Not an actor and not `@MainActor`: inference is a long synchronous C call,
/// so callers run it off the main actor themselves. One instance is single-use
/// per job and not safe to share across concurrent jobs — the context carries
/// streaming state.
enum EchoCancellerError: LocalizedError {
    case tooShort(samples: Int)
    case tooLong(samples: Int)
    case processingFailed(code: Int32, reason: String)

    var errorDescription: String? {
        switch self {
        case let .tooShort(samples):
            "recording too short for echo cancellation (\(samples) samples)"

        case let .tooLong(samples):
            "recording too long for echo cancellation (\(samples) samples)"

        case let .processingFailed(code, reason):
            "echo cancellation failed (\(code)): \(reason)"
        }
    }
}

final class EchoCanceller {
    /// LocalVQE's opaque context. Zero means "not created".
    private let ctx: localvqe_ctx_t

    /// The model needs at least this many samples in one call.
    static let minimumSamples = 512

    init?(modelPath: URL) {
        let created = modelPath.path.withCString { localvqe_new($0) }
        guard created != 0 else {
            let reason = String(cString: localvqe_last_error(0))
            logger.error("echo_canceller_init_failed reason=\(reason, privacy: .public)")
            return nil
        }
        ctx = created
    }

    deinit {
        localvqe_free(ctx)
    }

    /// Sample rate the model expects. The pipeline resamples to 16 kHz before
    /// this point, so a mismatch means an upstream change, not a user problem.
    var sampleRate: Int {
        Int(localvqe_sample_rate(ctx))
    }

    /// Runs the canceller over a whole track.
    ///
    /// `mic` and `reference` are aligned as the recorder produced them; any
    /// track-start offset must already have been applied by the caller, because
    /// the model estimates only the acoustic delay, not a file offset.
    ///
    /// Throws rather than returning partial audio on any failure, so a caller
    /// falls back to the raw track instead of transcribing something half
    /// processed. Every throw is recoverable: the recording is still usable,
    /// just not cleaned.
    func process(mic: [Float], reference: [Float]) throws -> [Float] {
        let n = min(mic.count, reference.count)
        guard n >= Self.minimumSamples else {
            throw EchoCancellerError.tooShort(samples: n)
        }
        // The C API counts samples in an Int32. At 16 kHz that ceiling is ~37
        // hours, far past anything real, but converting past it TRAPS — a
        // process kill inside a detached task, not the recoverable throw this
        // function promises.
        guard n <= Int(Int32.max) else {
            throw EchoCancellerError.tooLong(samples: n)
        }
        var out = [Float](repeating: 0, count: n)
        let rc = out.withUnsafeMutableBufferPointer { outBuf -> Int32 in
            mic.withUnsafeBufferPointer { micBuf in
                reference.withUnsafeBufferPointer { refBuf in
                    localvqe_process_f32(ctx, micBuf.baseAddress, refBuf.baseAddress, Int32(n), outBuf.baseAddress)
                }
            }
        }
        guard rc == 0 else {
            throw EchoCancellerError.processingFailed(code: rc, reason: String(cString: localvqe_last_error(ctx)))
        }
        // The mic track can be longer than the reference; everything past the
        // overlap had no reference to cancel against and is passed through, so
        // the returned track keeps the caller's original length.
        let tail = mic.count > n ? Array(mic[n...]) : []
        return realign(out, hop: Int(localvqe_hop_length(ctx)), tail: mic[..<n]) + tail
    }

    /// Removes the model's processing delay so the returned track sits on the
    /// caller's timeline.
    ///
    /// **Measured, not read.** LocalVQE's header states the output is
    /// sample-aligned to the input; cross-correlating a real run says it lags
    /// by exactly one hop (256 samples, 16 ms). `EchoCancellerTests` pins that
    /// measurement, so if a model update ever makes the header true the test
    /// says so instead of the audio quietly drifting.
    ///
    /// It matters because this track is merged and diarized against the app
    /// track: an uncorrected 16 ms would push every microphone segment late by
    /// more than one detector frame, on the exact recordings already known to
    /// have an alignment problem.
    private func realign(_ out: [Float], hop: Int, tail: ArraySlice<Float>) -> [Float] {
        guard hop > 0, out.count > hop else { return out }
        // The first hop is a synthesis-window ramp from zero, so dropping it
        // costs nothing real. The shift leaves the last hop with no cleaned
        // sample behind it, so it is filled from the untouched microphone
        // rather than with silence: 16 ms of uncancelled audio is a better
        // splice than 16 ms of nothing.
        return Array(out[hop...]) + Array(tail.suffix(hop))
    }
}
